-- 測試輔助函式。刻意不包在 transaction 裡，讓後面的測試檔都能用。
-- 測試檔依檔名順序執行，所以這個檔案要排在最前面。

create extension if not exists pgtap with schema extensions;
create schema if not exists tests;
grant usage on schema tests to authenticated, anon;

-- 建立一個有 profile 的使用者。
create or replace function tests.create_user(p_name text)
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
  insert into public.profiles (id, display_name, terms_accepted_at) values (uid, p_name, now());
  return uid;
end;
$$;

-- 切換成某個使用者（authenticated + JWT sub）。
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

-- 用名字記住 id，讓 throws_ok 等字串裡的 SQL 也拿得到。
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

-- 以某人身分建立群組、加入群組。
create or replace function tests.create_group(p_owner uuid, p_name text)
returns uuid
language plpgsql
as $$
declare
  gid uuid;
begin
  perform tests.login_as(p_owner);
  select id into gid from public.create_group(p_name);
  perform tests.logout();
  return gid;
end;
$$;

create or replace function tests.join(p_user_id uuid, p_group_id uuid)
returns void
language plpgsql
as $$
declare
  code text;
begin
  select invite_code into code from public.groups where id = p_group_id;
  perform tests.login_as(p_user_id);
  perform public.join_group(code);
  perform tests.logout();
end;
$$;

-- 模擬檔案已經傳到 Storage（直接寫 storage.objects，不經過 policy）。
create or replace function tests.put_object(p_user_id uuid, p_group_id uuid)
returns text
language plpgsql
as $$
declare
  path text := p_group_id::text || '/' || p_user_id::text || '/' || gen_random_uuid()::text || '.jpg';
begin
  insert into storage.objects (bucket_id, name, owner) values ('photos', path, p_user_id);
  return path;
end;
$$;

-- 以某人身分完成一次上傳（放檔案 + upload_photo）。
create or replace function tests.upload(p_user_id uuid, p_group_id uuid, p_taken_at timestamp default null)
returns uuid
language plpgsql
as $$
declare
  path text := tests.put_object(p_user_id, p_group_id);
  pid uuid;
begin
  perform tests.login_as(p_user_id);
  select id into pid from public.upload_photo(p_group_id, path, p_taken_at);
  perform tests.logout();
  return pid;
end;
$$;

-- 把照片往前推（同時改 day），模擬過去上傳的照片。
create or replace function tests.backdate(p_photo_id uuid, p_age interval)
returns void
language sql
as $$
  update public.photos
  set created_at = now() - p_age, day = public.swapee_day(now() - p_age)
  where id = p_photo_id
$$;

-- 以某人身分 claim，回傳 status 或收到的 photo_id。
create or replace function tests.claim(p_user_id uuid, p_group_id uuid)
returns jsonb
language plpgsql
as $$
declare
  result jsonb;
begin
  perform tests.login_as(p_user_id);
  result := public.claim_photo(p_group_id);
  perform tests.logout();
  return result;
end;
$$;

grant execute on all functions in schema tests to authenticated, anon;

begin;
select plan(1);
select has_function('tests', 'create_user', array['text']);
select * from finish();
rollback;
