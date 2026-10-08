-- RPCs the app calls. Errors are raised as `raise exception '<code>'`; the app maps the message to text:
--   not_authenticated, profile_required, invalid_time_zone, closed, invalid_day, already_written,
--   invalid_path, file_missing, text_required, text_too_long, entry_not_found, already_sent, expired,
--   invalid_username, username_taken, too_many_attempts, own_username, too_many_friends,
--   request_not_found, user_not_found, invalid_group_name, too_many_groups, group_not_found

-- ─── Helpers ───────────────────────────────────────────────

create function private.current_user_with_profile()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not_authenticated';
  end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'profile_required';
  end if;
  return uid;
end;
$$;

-- Keeps line breaks (at most one blank line in a row); tidies spaces around them and at the ends.
create function private.normalize_text(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    btrim(
      regexp_replace(
        regexp_replace(
          regexp_replace(replace(coalesce(p_text, ''), E'\r\n', E'\n'), '[ \t]+', ' ', 'g'),
          ' ?\n ?', E'\n', 'g'),
        '\n{3,}', E'\n\n', 'g'),
      E' \n\t'),
    '')
$$;

-- "@Alice.Smith " → "alice.smith". Validity is checked separately.
create function private.clean_username(p_username text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(btrim(coalesce(p_username, '')), '^@', ''))
$$;

-- Instagram's rules: 1–30 of a–z, 0–9, "." and "_"; no leading, trailing or doubled period.
create function private.is_valid_username(p_username text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_username ~ '^[a-z0-9._]{1,30}$' and p_username !~ '(^\.|\.$|\.\.)'
$$;

-- Names nobody can take.
create function private.is_reserved_username(p_username text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_username in ('lune', 'lune.app', 'admin', 'administrator', 'support', 'help', 'official',
                        'staff', 'team', 'moderator', 'root', 'system', 'null', 'undefined', 'me', 'you')
$$;

-- Serializes friend-count checks per person.
create function private.lock_friends_of(p_user_id uuid)
returns void
language sql
volatile
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('lune:friends-of:' || p_user_id::text, 0))
$$;

create function private.friend_count(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.friendships where p_user_id in (user_a, user_b)
$$;

create function private.make_friends(a uuid, b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.lock_friends_of(least(a, b));
  perform private.lock_friends_of(greatest(a, b));
  if private.friend_count(a) >= 1000 or private.friend_count(b) >= 1000 then
    raise exception 'too_many_friends';
  end if;
  insert into public.friendships (user_a, user_b) values (least(a, b), greatest(a, b))
  on conflict do nothing;
  delete from public.friend_requests
  where (from_id = a and to_id = b) or (from_id = b and to_id = a);
end;
$$;

-- A page as the app sees it. Who it was sent to is included only for the writer.
create function private.entry_json(p_entry_id uuid, p_viewer uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'entry_id', e.id,
    'user_id', e.user_id,
    'name', p.display_name,
    'username', p.username,
    'avatar_path', p.avatar_path,
    'day', e.day,
    'storage_path', e.storage_path,
    'text', e.text,
    'taken_at', e.taken_at,
    'created_at', e.created_at,
    'edited_at', e.edited_at,
    'sent_at', e.sent_at,
    'recipients', case when e.user_id = p_viewer then coalesce((
      select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', rp.display_name, 'username', rp.username, 'avatar_path', rp.avatar_path)
                       order by lower(rp.display_name))
      from public.entry_recipients r
      join public.profiles rp on rp.id = r.user_id
      where r.entry_id = e.id
    ), '[]'::jsonb) end
  )
  from public.entries e
  join public.profiles p on p.id = e.user_id
  where e.id = p_entry_id
$$;

-- Sends a page to those of p_recipients who are the writer's friends (others are skipped: someone may
-- have left since the app loaded its list). The first recipient turns the page into a letter.
create function private.send_entry(p_entry_id uuid, p_writer uuid, p_recipients uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with added as (
    insert into public.entry_recipients (entry_id, user_id)
    select p_entry_id, r.id
    from (select distinct unnest(coalesce(p_recipients, '{}')) as id) r
    where r.id <> p_writer
      and private.are_friends(p_writer, r.id)
      and not private.is_blocked_between(p_writer, r.id)
    on conflict do nothing
    returning 1
  )
  update public.entries set sent_at = coalesce(sent_at, now())
  where id = p_entry_id and exists (select 1 from added);
end;
$$;

-- A capture time more than a day in the future is treated as unknown.
create function private.clean_taken_at(p_taken_at timestamp)
returns timestamp
language sql
stable
set search_path = ''
as $$
  select case when p_taken_at <= (now() at time zone 'UTC') + interval '1 day' then p_taken_at end
$$;

-- Your photo, uploaded to entries/{your id}/{uuid}.jpg.
create function private.check_photo_path(p_user_id uuid, p_path text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_path is null or p_path !~ private.entry_path_pattern() or split_part(p_path, '/', 1) <> p_user_id::text then
    raise exception 'invalid_path';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'entries' and name = p_path) then
    raise exception 'file_missing';
  end if;
end;
$$;

create function private.check_text(p_text text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  body text := private.normalize_text(p_text);
begin
  if body is null then
    raise exception 'text_required';
  end if;
  if char_length(body) > 500 then
    raise exception 'text_too_long';
  end if;
  return body;
end;
$$;

-- ─── Profile ───────────────────────────────────────────────

-- First sign-in: set a name and accept the terms. Also used to change the name later.
create function public.save_profile(p_display_name text, p_accept_terms boolean default false)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  result public.profiles;
begin
  if uid is null then
    raise exception 'not_authenticated';
  end if;

  insert into public.profiles (id, display_name, terms_accepted_at)
  values (uid, btrim(p_display_name), case when p_accept_terms then now() end)
  on conflict (id) do update
    set display_name = excluded.display_name,
        terms_accepted_at = coalesce(public.profiles.terms_accepted_at, excluded.terms_accepted_at)
  returning * into result;
  return result;
end;
$$;

-- Choose or change your username (the old one is freed).
create function public.set_username(p_username text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  name text := private.clean_username(p_username);
  result public.profiles;
begin
  if not private.is_valid_username(name) then
    raise exception 'invalid_username';
  end if;
  if private.is_reserved_username(name) then
    raise exception 'username_taken';
  end if;
  begin
    update public.profiles set username = name where id = uid returning * into result;
  exception when unique_violation then
    raise exception 'username_taken';
  end;
  return result;
end;
$$;

-- Upload the photo to avatars/{your id}/{uuid}.jpg first, then call this. The old one is deleted.
create function public.set_avatar(p_path text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  result public.profiles;
begin
  if p_path !~ private.entry_path_pattern() or split_part(p_path, '/', 1) <> uid::text then
    raise exception 'invalid_path';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'avatars' and name = p_path) then
    raise exception 'file_missing';
  end if;
  update public.profiles set avatar_path = p_path where id = uid returning * into result;
  return result;
end;
$$;

create function public.remove_avatar()
returns public.profiles
language sql
security definer
set search_path = ''
as $$
  update public.profiles set avatar_path = null where id = private.current_user_with_profile() returning *
$$;

-- For checking while typing. Your own current username counts as available.
create function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_valid_username(private.clean_username(p_username))
     and not private.is_reserved_username(private.clean_username(p_username))
     and not exists (
       select 1 from public.profiles
       where username = private.clean_username(p_username) and id <> auth.uid()
     )
$$;

-- The app reports its time zone on launch and whenever it changes.
create function public.set_time_zone(p_time_zone text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'invalid_time_zone';
  end if;
  update public.profiles set time_zone = p_time_zone where id = uid;
end;
$$;

-- Apple requires in-app account deletion. Everything cascades; photos go to the deletion queue.
create function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not_authenticated';
  end if;
  delete from auth.users where id = uid;
end;
$$;

-- ─── Tonight ───────────────────────────────────────────────

-- The caller's current day: their page, and the letters friends sent them for it. Letters open once
-- you've written today's page (sending it to anyone or no one); until then they're listed as locked.
-- A day you didn't write stays locked until it ends.
create function public.tonight()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  tz text := private.time_zone_of(uid);
  local_now timestamp := now() at time zone tz;
  today date := private.user_today(uid);
  open boolean := private.is_open(uid);
  written boolean := private.has_written(uid, today);
begin
  return jsonb_build_object(
    'today', today,
    'open', open,
    -- Writing closes at 04:00 and reopens at 20:00 on the same local date.
    'opens_at', case when open then null else (local_now::date + time '20:00') at time zone tz end,
    'closes_at', case when open then ((today + 1) + time '04:00') at time zone tz end,
    -- When today's letters disappear and a new day starts.
    'ends_at', ((today + 1) + time '20:00') at time zone tz,
    'mine', (select private.entry_json(e.id, uid) from public.entries e where e.user_id = uid and e.day = today),
    'letters', case when written then coalesce((
      select jsonb_agg(private.entry_json(e.id, uid) order by r.sent_at desc, e.id)
      from public.entry_recipients r
      join public.entries e on e.id = r.entry_id
      where r.user_id = uid and private.is_letter_to(e.id, uid)
    ), '[]'::jsonb) else '[]'::jsonb end,
    'locked', case when written then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.display_name, 'username', p.username, 'avatar_path', p.avatar_path, 'sent_at', r.sent_at)
                       order by r.sent_at desc, e.id)
      from public.entry_recipients r
      join public.entries e on e.id = r.entry_id
      join public.profiles p on p.id = e.user_id
      where r.user_id = uid and private.is_letter_to(e.id, uid)
    ), '[]'::jsonb) end
  );
end;
$$;

-- ─── Writing ───────────────────────────────────────────────

-- Upload the photo to entries/{your id}/{uuid}.jpg first, then call this. Only tonight's page, once,
-- while writing is open. p_recipients are friends' ids (the app expands "all friends" and groups);
-- an empty list keeps the page to yourself. Sending is immediate and final.
create function public.write_entry(
  p_day date,
  p_storage_path text,
  p_text text,
  p_taken_at timestamp default null,
  p_recipients uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  body text := private.check_text(p_text);
  new_id uuid;
begin
  if not private.can_write(uid) then
    raise exception 'closed';
  end if;
  if p_day is distinct from private.user_today(uid) then
    raise exception 'invalid_day';
  end if;
  if private.has_written(uid, p_day) then
    raise exception 'already_written';
  end if;
  perform private.check_photo_path(uid, p_storage_path);

  begin
    insert into public.entries (user_id, day, storage_path, text, taken_at)
    values (uid, p_day, p_storage_path, body, private.clean_taken_at(p_taken_at))
    returning id into new_id;
  exception when unique_violation then
    raise exception 'already_written';
  end;

  perform private.send_entry(new_id, uid, p_recipients);
  return private.entry_json(new_id, uid);
end;
$$;

-- Sends one of your pages to more friends, until its day ends. Once sent it can't be edited.
create function public.add_recipients(p_entry_id uuid, p_recipients uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  page_day date;
begin
  -- Locked so a concurrent edit can't slip in after the page is sent.
  select day into page_day from public.entries where id = p_entry_id and user_id = uid for update;
  if not found then
    raise exception 'entry_not_found';
  end if;
  if page_day <> private.user_today(uid) then
    raise exception 'expired';
  end if;

  perform private.send_entry(p_entry_id, uid, p_recipients);
  return private.entry_json(p_entry_id, uid);
end;
$$;

-- A page you haven't sent to anyone can be changed any time: its text, and optionally its photo
-- (upload the new one first; the old file is deleted).
create function public.update_entry(
  p_entry_id uuid,
  p_text text,
  p_storage_path text default null,
  p_taken_at timestamp default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  body text := private.check_text(p_text);
  page public.entries;
begin
  select * into page from public.entries where id = p_entry_id and user_id = uid for update;
  if not found then
    raise exception 'entry_not_found';
  end if;
  if page.sent_at is not null then
    raise exception 'already_sent';
  end if;

  if p_storage_path is not null and p_storage_path <> page.storage_path then
    perform private.check_photo_path(uid, p_storage_path);
    begin
      update public.entries
      set storage_path = p_storage_path, taken_at = private.clean_taken_at(p_taken_at)
      where id = p_entry_id;
    exception when unique_violation then
      raise exception 'invalid_path';
    end;
  end if;

  update public.entries set text = body, edited_at = now() where id = p_entry_id;
  return private.entry_json(p_entry_id, uid);
end;
$$;

-- A page you haven't sent to anyone can be deleted any time (its photo too).
create function public.delete_entry(p_entry_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  page public.entries;
begin
  select * into page from public.entries where id = p_entry_id and user_id = uid for update;
  if not found then
    raise exception 'entry_not_found';
  end if;
  if page.sent_at is not null then
    raise exception 'already_sent';
  end if;
  delete from public.entries where id = p_entry_id;
end;
$$;

-- ─── Your diary ────────────────────────────────────────────

-- Your own pages, newest first, before a given day. The 30-day limit for free users is in the app.
create function public.my_entries(p_before date default null, p_limit integer default 60)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(private.entry_json(e.id, e.user_id) order by e.day desc), '[]'::jsonb)
  from (
    select id, user_id, day from public.entries
    where user_id = private.current_user_with_profile()
      and (p_before is null or day < p_before)
    order by day desc
    limit least(greatest(p_limit, 1), 200)
  ) e
$$;

-- Everything you wrote, oldest first, for export (always free).
create function public.export_entries()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(private.entry_json(e.id, e.user_id) order by e.day), '[]'::jsonb)
  from public.entries e
  where e.user_id = private.current_user_with_profile()
$$;

-- ─── Friends ───────────────────────────────────────────────

-- Looks someone up by their exact username, to show who it is before sending a request.
-- Returns null when there's no such person (or a block between you); misses are rate limited.
-- relationship: "self", "friend", "requested" (you asked), "incoming" (they asked you) or "none".
create function public.find_user(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  target public.profiles;
begin
  if (
    select count(*) from private.username_lookup_failures
    where user_id = uid and attempted_at > now() - interval '1 hour'
  ) >= 30 then
    raise exception 'too_many_attempts';
  end if;

  select * into target from public.profiles where username = private.clean_username(p_username);
  if not found or private.is_blocked_between(uid, target.id) then
    insert into private.username_lookup_failures (user_id) values (uid);
    return null;
  end if;

  return jsonb_build_object(
    'user_id', target.id,
    'name', target.display_name,
    'username', target.username,
    'avatar_path', target.avatar_path,
    'relationship', case
      when target.id = uid then 'self'
      when private.are_friends(uid, target.id) then 'friend'
      when exists (select 1 from public.friend_requests where from_id = uid and to_id = target.id) then 'requested'
      when exists (select 1 from public.friend_requests where from_id = target.id and to_id = uid) then 'incoming'
      else 'none'
    end
  );
end;
$$;

-- Sends someone a request by username, or makes you friends if they already asked you.
-- Returns {"status": "requested" | "friends" | "already_friends" | "not_found", "name"?, "username"?}.
-- Not found doesn't raise, so the failed attempt is kept for rate limiting.
create function public.add_friend(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  target public.profiles;
begin
  if (
    select count(*) from private.username_lookup_failures
    where user_id = uid and attempted_at > now() - interval '1 hour'
  ) >= 30 then
    raise exception 'too_many_attempts';
  end if;

  select * into target from public.profiles where username = private.clean_username(p_username);
  if not found or private.is_blocked_between(uid, target.id) then
    insert into private.username_lookup_failures (user_id) values (uid);
    return jsonb_build_object('status', 'not_found');
  end if;
  if target.id = uid then
    raise exception 'own_username';
  end if;
  if private.are_friends(uid, target.id) then
    return jsonb_build_object('status', 'already_friends', 'name', target.display_name, 'username', target.username);
  end if;

  if exists (select 1 from public.friend_requests where from_id = target.id and to_id = uid) then
    perform private.make_friends(uid, target.id);
    return jsonb_build_object('status', 'friends', 'name', target.display_name, 'username', target.username);
  end if;

  perform private.lock_friends_of(uid);
  if private.friend_count(uid) >= 1000 then
    raise exception 'too_many_friends';
  end if;
  insert into public.friend_requests (from_id, to_id) values (uid, target.id)
  on conflict do nothing;
  return jsonb_build_object('status', 'requested', 'name', target.display_name, 'username', target.username);
end;
$$;

create function public.respond_friend_request(p_from_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
begin
  if not exists (select 1 from public.friend_requests where from_id = p_from_id and to_id = uid) then
    raise exception 'request_not_found';
  end if;
  if p_accept then
    perform private.make_friends(uid, p_from_id);
  else
    delete from public.friend_requests where from_id = p_from_id and to_id = uid;
  end if;
end;
$$;

-- Requests waiting for you to answer, newest first.
create function public.friend_requests()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', r.from_id, 'name', p.display_name, 'username', p.username, 'avatar_path', p.avatar_path, 'created_at', r.created_at)
                            order by r.created_at desc), '[]'::jsonb)
  from public.friend_requests r
  join public.profiles p on p.id = r.from_id
  where r.to_id = private.current_user_with_profile()
$$;

create function public.friends()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.display_name, 'username', p.username, 'avatar_path', p.avatar_path, 'since', f.created_at)
                            order by lower(p.display_name)), '[]'::jsonb)
  from public.friendships f
  join public.profiles p on p.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
  where private.current_user_with_profile() in (f.user_a, f.user_b)
$$;

create function public.remove_friend(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.friendships
  where user_a = least(private.current_user_with_profile(), p_user_id)
    and user_b = greatest(private.current_user_with_profile(), p_user_id)
$$;

-- Blocking also ends the friendship and any requests between you.
create function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
begin
  if p_user_id = uid or not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user_not_found';
  end if;
  insert into public.blocks (blocker_id, blocked_id) values (uid, p_user_id)
  on conflict do nothing;
  delete from public.friendships where user_a = least(uid, p_user_id) and user_b = greatest(uid, p_user_id);
  delete from public.friend_requests
  where (from_id = uid and to_id = p_user_id) or (from_id = p_user_id and to_id = uid);
end;
$$;

-- You can report any page you can see.
create function public.report_entry(p_entry_id uuid, p_reason text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  owner uuid;
begin
  select e.user_id into owner
  from public.entries e
  where e.id = p_entry_id and e.user_id <> uid and private.can_view_entry(e.id);

  if owner is null then
    raise exception 'entry_not_found';
  end if;

  insert into public.reports (reporter_id, entry_id, reported_user_id, reason)
  values (uid, p_entry_id, owner, left(coalesce(p_reason, ''), 500));
end;
$$;

-- ─── Groups ────────────────────────────────────────────────
-- Your own lists of friends, for sending to several at once. Nobody else sees them.

create function public.groups()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'member_ids', coalesce((select jsonb_agg(m.user_id order by m.user_id) from public.friend_group_members m where m.group_id = g.id), '[]'::jsonb)
  ) order by lower(g.name), g.created_at), '[]'::jsonb)
  from public.friend_groups g
  where g.owner_id = private.current_user_with_profile()
$$;

-- Creates a group (p_group_id null) or renames it and replaces its members. Non-friends are skipped.
create function public.save_group(p_group_id uuid, p_name text, p_member_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  clean_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  gid uuid := p_group_id;
begin
  if char_length(clean_name) not between 1 and 30 then
    raise exception 'invalid_group_name';
  end if;

  if gid is null then
    perform pg_advisory_xact_lock(hashtextextended('lune:groups-of:' || uid::text, 0));
    if (select count(*) from public.friend_groups where owner_id = uid) >= 100 then
      raise exception 'too_many_groups';
    end if;
    insert into public.friend_groups (owner_id, name) values (uid, clean_name) returning id into gid;
  else
    update public.friend_groups set name = clean_name where id = gid and owner_id = uid;
    if not found then
      raise exception 'group_not_found';
    end if;
    delete from public.friend_group_members where group_id = gid;
  end if;

  insert into public.friend_group_members (group_id, user_id)
  select gid, m.id
  from (select distinct unnest(coalesce(p_member_ids, '{}')) as id) m
  where private.are_friends(uid, m.id);

  return (
    select jsonb_build_object(
      'id', g.id,
      'name', g.name,
      'member_ids', coalesce((select jsonb_agg(m.user_id order by m.user_id) from public.friend_group_members m where m.group_id = g.id), '[]'::jsonb)
    )
    from public.friend_groups g where g.id = gid
  );
end;
$$;

create function public.delete_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.friend_groups where id = p_group_id and owner_id = private.current_user_with_profile();
  if not found then
    raise exception 'group_not_found';
  end if;
end;
$$;

-- ─── Push devices ──────────────────────────────────────────

create function public.register_device(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
begin
  insert into public.devices (token, user_id) values (p_token, uid)
  on conflict (token) do update set user_id = excluded.user_id, created_at = now();
end;
$$;

-- Called before signing out so this device stops getting the account's notifications.
create function public.unregister_device(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.devices where token = p_token and user_id = auth.uid()
$$;

-- ─── Permissions ───────────────────────────────────────────

revoke execute on function
  public.save_profile(text, boolean),
  public.set_username(text),
  public.set_avatar(text),
  public.remove_avatar(),
  public.username_available(text),
  public.find_user(text),
  public.set_time_zone(text),
  public.delete_account(),
  public.tonight(),
  public.write_entry(date, text, text, timestamp, uuid[]),
  public.add_recipients(uuid, uuid[]),
  public.update_entry(uuid, text, text, timestamp),
  public.delete_entry(uuid),
  public.my_entries(date, integer),
  public.export_entries(),
  public.add_friend(text),
  public.respond_friend_request(uuid, boolean),
  public.friend_requests(),
  public.friends(),
  public.remove_friend(uuid),
  public.block_user(uuid),
  public.report_entry(uuid, text),
  public.groups(),
  public.save_group(uuid, text, uuid[]),
  public.delete_group(uuid),
  public.register_device(text),
  public.unregister_device(text)
from public, anon;

grant execute on function
  public.save_profile(text, boolean),
  public.set_username(text),
  public.set_avatar(text),
  public.remove_avatar(),
  public.username_available(text),
  public.find_user(text),
  public.set_time_zone(text),
  public.delete_account(),
  public.tonight(),
  public.write_entry(date, text, text, timestamp, uuid[]),
  public.add_recipients(uuid, uuid[]),
  public.update_entry(uuid, text, text, timestamp),
  public.delete_entry(uuid),
  public.my_entries(date, integer),
  public.export_entries(),
  public.add_friend(text),
  public.respond_friend_request(uuid, boolean),
  public.friend_requests(),
  public.friends(),
  public.remove_friend(uuid),
  public.block_user(uuid),
  public.report_entry(uuid, text),
  public.groups(),
  public.save_group(uuid, text, uuid[]),
  public.delete_group(uuid),
  public.register_device(text),
  public.unregister_device(text)
to authenticated;
