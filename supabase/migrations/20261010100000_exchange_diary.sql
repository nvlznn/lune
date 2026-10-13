-- Exchange diary. A page written on night D is delivered at the reader's 20:00 on D+1, and can be
-- read only that night (until writing closes at 04:00). To read yesterday's letters you first write
-- (and send) your own page for the new day. Sent pages are already final, so nothing is editable.
--
--   day D night:  write, send            → nothing arrives yet
--   day D+1 20:00 → 04:00:  yesterday's letters are here, locked until you write today's page
--   04:00 on D+2: they disappear
--
-- The review account is always open, so its letters (always dated yesterday) are always readable.

-- A letter someone sent you: still friends, no block, written yesterday, and the diary is open.
-- Whether you've unlocked it is separate (has_written).
create or replace function private.is_letter_to(p_entry_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_open(p_user_id) and exists (
    select 1 from public.entries e
    join public.entry_recipients r on r.entry_id = e.id
    where e.id = p_entry_id
      and r.user_id = p_user_id
      and e.day = private.user_today(p_user_id) - 1
      and private.are_friends(p_user_id, e.user_id)
      and not private.is_blocked_between(p_user_id, e.user_id)
  )
$$;

-- Your own pages always. Someone else's only if it's a letter to you and you wrote today's page.
create or replace function private.can_view_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.entries e
    where e.id = p_entry_id
      and (
        e.user_id = auth.uid()
        or (private.is_letter_to(e.id, auth.uid())
            and private.has_written(auth.uid(), private.user_today(auth.uid())))
      )
  )
$$;

-- Nothing is deliverable at send time any more, so the "a friend sent you a page" push goes.
-- The one push left is "Tonight's page is open — Alice and Bob wrote to you" at 20:00.
drop trigger entry_recipients_after_insert on public.entry_recipients;
drop function private.on_letters_sent();
drop function public.push_targets_letter(uuid, uuid[]);

-- Review account: its friends' letters are always dated yesterday.
create or replace function public.setup_review_account(p_reviewer uuid, p_name text, p_username text, p_friends jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  friend jsonb;
  friend_id uuid;
  page_id uuid;
begin
  insert into public.profiles (id, display_name, username, terms_accepted_at)
  values (p_reviewer, p_name, p_username, now())
  on conflict (id) do update set display_name = excluded.display_name, username = excluded.username;
  insert into private.review_accounts (user_id, role) values (p_reviewer, 'reviewer')
  on conflict (user_id) do update set role = excluded.role;

  for friend in select value from jsonb_array_elements(p_friends) loop
    friend_id := (friend ->> 'user_id')::uuid;
    insert into public.profiles (id, display_name, username, avatar_path, terms_accepted_at)
    values (friend_id, friend ->> 'name', friend ->> 'username', friend ->> 'avatar_path', now())
    on conflict (id) do update
      set display_name = excluded.display_name, username = excluded.username, avatar_path = excluded.avatar_path;
    insert into private.review_accounts (user_id, role) values (friend_id, 'friend')
    on conflict (user_id) do update set role = excluded.role;
    insert into public.friendships (user_a, user_b)
    values (least(p_reviewer, friend_id), greatest(p_reviewer, friend_id))
    on conflict do nothing;

    -- One letter each, dated yesterday for the reviewer. An earlier one (and its photo) is replaced.
    delete from public.entries where user_id = friend_id;
    insert into public.entries (user_id, day, storage_path, text, sent_at)
    values (friend_id, private.user_today(p_reviewer) - 1, friend ->> 'storage_path', friend ->> 'text', now())
    returning id into page_id;
    insert into public.entry_recipients (entry_id, user_id) values (page_id, p_reviewer);
  end loop;
end;
$$;

-- When the reviewer's day changes, its friends' letters move to the new "yesterday", as if just sent.
create or replace function private.refresh_review_letters()
returns void
language sql
security definer
set search_path = ''
as $$
  with reviewer as (
    select user_id, private.user_today(user_id) - 1 as letter_day
    from private.review_accounts
    where role = 'reviewer'
  ),
  moved as (
    update public.entries e
    set day = r.letter_day, created_at = now(), sent_at = now()
    from reviewer r, public.entry_recipients er, private.review_accounts f
    where f.role = 'friend'
      and e.user_id = f.user_id
      and er.entry_id = e.id
      and er.user_id = r.user_id
      and e.day <> r.letter_day
    returning e.id, r.user_id as reviewer_id
  )
  update public.entry_recipients er
  set sent_at = now()
  from moved m
  where er.entry_id = m.id and er.user_id = m.reviewer_id
$$;
