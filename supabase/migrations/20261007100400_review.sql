-- App Review. Apple's reviewers sign in with email (hold the moon on the sign-in screen for two
-- seconds) to an account that is always open and always has letters from a few friends, so the
-- whole app can be tried at any hour. scripts/review-account creates the users and uploads the
-- photos, then calls setup_review_account. Real accounts are never affected.

-- Makes p_reviewer the review account and gives it friends who each sent it a letter today.
-- p_friends: [{"user_id", "name", "username", "avatar_path", "storage_path", "text"}], all users
-- already created in Auth and their files already uploaded. Safe to run again: letters are replaced.
create function public.setup_review_account(p_reviewer uuid, p_name text, p_username text, p_friends jsonb)
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

    -- One letter each, for the reviewer's current day. An earlier one (and its photo) is replaced.
    delete from public.entries where user_id = friend_id;
    insert into public.entries (user_id, day, storage_path, text, sent_at)
    values (friend_id, private.user_today(p_reviewer), friend ->> 'storage_path', friend ->> 'text', now())
    returning id into page_id;
    insert into public.entry_recipients (entry_id, user_id) values (page_id, p_reviewer);
  end loop;
end;
$$;

revoke execute on function public.setup_review_account(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.setup_review_account(uuid, text, text, jsonb) to service_role;

-- When the reviewer's day changes, its friends' letters move to the new day, as if just sent.
create function private.refresh_review_letters()
returns void
language sql
security definer
set search_path = ''
as $$
  with reviewer as (
    select user_id, private.user_today(user_id) as today
    from private.review_accounts
    where role = 'reviewer'
  ),
  moved as (
    update public.entries e
    set day = r.today, created_at = now(), sent_at = now()
    from reviewer r, public.entry_recipients er, private.review_accounts f
    where f.role = 'friend'
      and e.user_id = f.user_id
      and er.entry_id = e.id
      and er.user_id = r.user_id
      and e.day <> r.today
    returning e.id, r.user_id as reviewer_id
  )
  update public.entry_recipients er
  set sent_at = now()
  from moved m
  where er.entry_id = m.id and er.user_id = m.reviewer_id
$$;

select cron.schedule('lune-review-letters', '*/10 * * * *', $$ select private.refresh_review_letters() $$);
