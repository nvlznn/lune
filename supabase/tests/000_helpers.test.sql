-- Test helpers. Not wrapped in a transaction, so every test file can use them.
-- Files run in name order, so this one must sort first.

create extension if not exists pgtap with schema extensions;
create schema if not exists tests;
grant usage on schema tests to authenticated, anon;

-- A time zone where the local hour is p_hour right now ("Etc/GMT-8" is UTC+8: the sign is inverted).
create or replace function tests.tz_for_hour(p_hour integer)
returns text
language plpgsql
stable
as $$
declare
  utc_hour integer := extract(hour from now() at time zone 'UTC');
  utc_offset integer := ((p_hour - utc_hour + 36) % 24) - 12;
begin
  return case
    when utc_offset = 0 then 'Etc/GMT'
    when utc_offset > 0 then 'Etc/GMT-' || utc_offset
    else 'Etc/GMT+' || (-utc_offset)
  end;
end;
$$;

-- A user with a profile, living where it's 22:00 (diary open) or 12:00 (closed).
create or replace function tests.create_user(p_name text, p_open boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (
    uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    p_name || '-' || uid::text || '@test.local', now(), now()
  );
  insert into public.profiles (id, display_name, username, time_zone, terms_accepted_at)
  values (uid, p_name, lower(p_name) || '_' || left(replace(uid::text, '-', ''), 8),
          tests.tz_for_hour(case when p_open then 22 else 12 end), now());
  return uid;
end;
$$;

create or replace function tests.set_open(p_user_id uuid, p_open boolean)
returns void
language sql
as $$
  update public.profiles set time_zone = tests.tz_for_hour(case when p_open then 22 else 12 end) where id = p_user_id
$$;

create or replace function tests.login_as(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

create or replace function tests.logout()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);
end;
$$;

-- Remember ids by name, so SQL inside throws_ok strings can use them.
create or replace function tests.remember(p_key text, p_id uuid)
returns uuid
language sql
as $$
  select set_config('tests.' || p_key, p_id::text, false)::uuid
$$;

create or replace function tests.id(p_key text)
returns uuid
language sql
stable
as $$
  select current_setting('tests.' || p_key)::uuid
$$;

create or replace function tests.befriend(a uuid, b uuid)
returns void
language sql
as $$
  insert into public.friendships (user_a, user_b) values (least(a, b), greatest(a, b)) on conflict do nothing
$$;

-- A file already in Storage (written directly, bypassing policies).
create or replace function tests.put_object(p_user_id uuid)
returns text
language plpgsql
as $$
declare
  path text := p_user_id::text || '/' || gen_random_uuid()::text || '.jpg';
begin
  insert into storage.objects (bucket_id, name, owner) values ('entries', path, p_user_id);
  return path;
end;
$$;

-- Writes tonight's page as the user through write_entry, sent to p_to (empty: only for themselves).
create or replace function tests.write(p_user_id uuid, p_to uuid[] default '{}', p_text text default 'A good day.')
returns uuid
language plpgsql
as $$
declare
  path text := tests.put_object(p_user_id);
  result jsonb;
begin
  perform tests.login_as(p_user_id);
  result := public.write_entry(private.user_today(p_user_id), path, p_text, null, p_to);
  perform tests.logout();
  return (result ->> 'entry_id')::uuid;
end;
$$;

-- A page from any day, straight into the table, sent to p_to.
create or replace function tests.page_on(p_user_id uuid, p_day date, p_to uuid[] default '{}')
returns uuid
language plpgsql
as $$
declare
  eid uuid;
begin
  insert into public.entries (user_id, day, storage_path, text, sent_at)
  values (p_user_id, p_day, tests.put_object(p_user_id), 'Older page.', case when cardinality(p_to) > 0 then now() end)
  returning id into eid;
  insert into public.entry_recipients (entry_id, user_id) select eid, unnest(p_to);
  return eid;
end;
$$;

create or replace function tests.tonight(p_user_id uuid)
returns jsonb
language plpgsql
as $$
declare
  result jsonb;
begin
  perform tests.login_as(p_user_id);
  result := public.tonight();
  perform tests.logout();
  return result;
end;
$$;

-- Letters someone can open right now, in the order tonight() lists them.
create or replace function tests.letters(p_user_id uuid)
returns uuid[]
language sql
as $$
  select coalesce(array_agg((page ->> 'entry_id')::uuid order by i), '{}')
  from jsonb_array_elements(tests.tonight(p_user_id) -> 'letters') with ordinality as t (page, i)
$$;

-- Names on the letters someone can't open yet.
create or replace function tests.locked(p_user_id uuid)
returns text[]
language sql
as $$
  select coalesce(array_agg(card ->> 'name' order by i), '{}')
  from jsonb_array_elements(tests.tonight(p_user_id) -> 'locked') with ordinality as t (card, i)
$$;

grant execute on all functions in schema tests to authenticated, anon;

begin;
select plan(1);
select has_function('tests', 'create_user', array['text', 'boolean']);
select * from finish();
rollback;
