-- 客戶端可呼叫的 RPC。錯誤一律用 raise exception '<code>'，客戶端依 message 對應文案：
--   not_authenticated, profile_required, not_member, too_many_groups, group_full,
--   too_many_attempts, already_uploaded_today, invalid_path, file_missing,
--   no_credits, photo_not_found, user_not_found

-- ─── 內部工具 ──────────────────────────────────────────────

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

create function private.require_member(p_user_id uuid, p_group_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.group_members where group_id = p_group_id and user_id = p_user_id
  ) then
    raise exception 'not_member';
  end if;
end;
$$;

-- 資格 = 在該群組的上傳張數 − 已收到的張數。不另外存。
create function private.credits(p_user_id uuid, p_group_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.photos where group_id = p_group_id and user_id = p_user_id)::integer
  - (select count(*) from public.deliveries where group_id = p_group_id and receiver_id = p_user_id)::integer
$$;

-- 照片池中最該配給這個人的一張：72 小時內、不是自己、還沒收過、雙方沒封鎖；
-- 被收過最少次的優先，同分隨機。上傳者仍是成員由 photos → group_members 的 FK 保證。
create function private.next_candidate(p_user_id uuid, p_group_id uuid)
returns uuid
language sql
volatile
security definer
set search_path = ''
as $$
  select p.id
  from public.photos p
  where p.group_id = p_group_id
    and p.user_id <> p_user_id
    and p.expired_at is null
    and p.created_at > now() - interval '72 hours'
    and not exists (
      select 1 from public.deliveries d
      where d.photo_id = p.id and d.receiver_id = p_user_id
    )
    and not private.is_blocked_between(p_user_id, p.user_id)
  order by
    (select count(*) from public.deliveries d where d.photo_id = p.id),
    random()
  limit 1
$$;

create function private.random_invite_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- 32 個字元，不含 0/O、1/I；256 是 32 的倍數，取餘數不會偏。
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  bytes bytea := extensions.gen_random_bytes(6);
  code text := '';
begin
  for i in 0..5 loop
    code := code || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  end loop;
  return code;
end;
$$;

-- 每個使用者的群組數上限檢查要序列化，避免同時建立／加入超過 10 個。
create function private.lock_user_groups(p_user_id uuid)
returns void
language sql
volatile
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('swapee:groups-of:' || p_user_id::text, 0))
$$;

-- 猜邀請碼的失敗紀錄（每小時最多 10 次）。
create table private.join_failures (
  user_id uuid not null references public.profiles (id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index join_failures_user_idx on private.join_failures (user_id, attempted_at);

-- ─── 個人資料 ──────────────────────────────────────────────

-- 第一次登入：設定顯示名稱並同意條款。之後也可用來改名。
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

-- Apple 要求 app 內可刪除帳號。cascade 會依序：離開所有群組（擁有者轉移）、
-- 刪除照片列（檔案排入刪除佇列）、收片紀錄、封鎖、裝置。
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

-- ─── 群組 ──────────────────────────────────────────────────

create function public.create_group(p_name text)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  g public.groups;
begin
  perform private.lock_user_groups(uid);
  if (select count(*) from public.group_members where user_id = uid) >= 10 then
    raise exception 'too_many_groups';
  end if;

  loop
    begin
      insert into public.groups (name, owner_id, invite_code)
      values (btrim(p_name), uid, private.random_invite_code())
      returning * into g;
      exit;
    exception when unique_violation then
      -- 邀請碼撞號，重抽。
    end;
  end loop;

  insert into public.group_members (group_id, user_id) values (g.id, uid);
  return g;
end;
$$;

-- 找不到邀請碼時回傳空陣列（不丟錯，失敗紀錄才不會被 rollback）。
-- 已經是成員則直接回傳該群組（冪等）。
create function public.join_group(p_code text)
returns setof public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  g public.groups;
begin
  if (
    select count(*) from private.join_failures
    where user_id = uid and attempted_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'too_many_attempts';
  end if;

  select * into g from public.groups where invite_code = code;
  if not found then
    insert into private.join_failures (user_id) values (uid);
    return;
  end if;

  if exists (select 1 from public.group_members where group_id = g.id and user_id = uid) then
    return next g;
    return;
  end if;

  perform private.lock_user_groups(uid);
  if (select count(*) from public.group_members where user_id = uid) >= 10 then
    raise exception 'too_many_groups';
  end if;

  -- 鎖住群組列，讓同一群組的加入一個一個來，人數上限才準。
  perform 1 from public.groups where id = g.id for update;
  if (select count(*) from public.group_members where group_id = g.id) >= 20 then
    raise exception 'group_full';
  end if;

  insert into public.group_members (group_id, user_id) values (g.id, uid);
  return next g;
end;
$$;

-- 照片、收片紀錄、擁有者轉移、最後一人時刪群組，都由 FK cascade 與 trigger 處理。
create function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
begin
  delete from public.group_members where group_id = p_group_id and user_id = uid;
  if not found then
    raise exception 'not_member';
  end if;
end;
$$;

-- 群組清單用：每個群組今天的狀態。
create function public.my_groups()
returns table (
  id uuid,
  name text,
  invite_code text,
  owner_id uuid,
  member_count integer,
  uploaded_today boolean,
  credits integer,
  last_received_at timestamptz,
  joined_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    g.id,
    g.name,
    g.invite_code,
    g.owner_id,
    (select count(*) from public.group_members m2 where m2.group_id = g.id)::integer,
    exists (
      select 1 from public.photos p
      where p.group_id = g.id and p.user_id = m.user_id and p.day = public.swapee_day()
    ),
    private.credits(m.user_id, g.id),
    (
      select max(d.delivered_at) from public.deliveries d
      where d.group_id = g.id and d.receiver_id = m.user_id
    ),
    m.joined_at
  from public.group_members m
  join public.groups g on g.id = m.group_id
  where m.user_id = auth.uid()
  order by m.joined_at
$$;

-- ─── 照片 ──────────────────────────────────────────────────

-- 客戶端先把檔案傳到 {group_id}/{自己的 user_id}/{uuid}.jpg，再呼叫這個登記。
-- day 由伺服器決定；同一個換日週期第二次呼叫會被拒絕。
create function public.upload_photo(
  p_group_id uuid,
  p_storage_path text,
  p_taken_at timestamp default null
)
returns public.photos
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  result public.photos;
begin
  perform private.require_member(uid, p_group_id);

  if p_storage_path !~ private.photo_path_pattern()
     or split_part(p_storage_path, '/', 1) <> p_group_id::text
     or split_part(p_storage_path, '/', 2) <> uid::text then
    raise exception 'invalid_path';
  end if;

  if exists (
    select 1 from public.photos
    where group_id = p_group_id and user_id = uid and day = public.swapee_day()
  ) then
    raise exception 'already_uploaded_today';
  end if;

  if not exists (
    select 1 from storage.objects where bucket_id = 'photos' and name = p_storage_path
  ) then
    raise exception 'file_missing';
  end if;

  begin
    insert into public.photos (group_id, user_id, day, storage_path, taken_at)
    values (
      p_group_id,
      uid,
      public.swapee_day(),
      p_storage_path,
      -- 明顯錯誤的拍攝時間（未來一天以上）視為讀不到。
      case when p_taken_at <= (now() at time zone 'UTC') + interval '1 day' then p_taken_at end
    )
    returning * into result;
  exception when unique_violation then
    raise exception 'already_uploaded_today';
  end;

  return result;
end;
$$;

-- 收一張照片。回傳 {"status": "waiting"} 或 {"status": "delivered", "photo": {...}}。
create function public.claim_photo(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  candidate uuid;
begin
  perform private.require_member(uid, p_group_id);

  -- 同一個 (使用者, 群組) 的 claim 一次只跑一個，避免超收。
  perform pg_advisory_xact_lock(
    hashtextextended('swapee:claim:' || uid::text || ':' || p_group_id::text, 0)
  );

  if private.credits(uid, p_group_id) <= 0 then
    raise exception 'no_credits';
  end if;

  candidate := private.next_candidate(uid, p_group_id);
  if candidate is null then
    return jsonb_build_object('status', 'waiting');
  end if;

  insert into public.deliveries (receiver_id, group_id, photo_id)
  values (uid, p_group_id, candidate);

  return jsonb_build_object(
    'status', 'delivered',
    'photo', private.received_photo_json(uid, candidate)
  );
end;
$$;

create function private.received_photo_json(p_receiver_id uuid, p_photo_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'photo_id', p.id,
    'sender_id', p.user_id,
    'sender_name', pr.display_name,
    'storage_path', p.storage_path,
    'taken_at', p.taken_at,
    'uploaded_at', p.created_at,
    'delivered_at', d.delivered_at
  )
  from public.photos p
  join public.profiles pr on pr.id = p.user_id
  join public.deliveries d on d.photo_id = p.id and d.receiver_id = p_receiver_id
  where p.id = p_photo_id
$$;

-- 群組畫面用：今天傳了沒、自己今天那張、剩幾次資格、最近 7 天收到的照片（新的在上）。
create function public.group_state(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  today_photo jsonb;
begin
  perform private.require_member(uid, p_group_id);

  select jsonb_build_object(
    'photo_id', p.id,
    'storage_path', p.storage_path,
    'taken_at', p.taken_at,
    'uploaded_at', p.created_at
  )
  into today_photo
  from public.photos p
  where p.group_id = p_group_id and p.user_id = uid and p.day = public.swapee_day();

  return jsonb_build_object(
    'uploaded_today', today_photo is not null,
    'today_photo', today_photo,
    'credits', private.credits(uid, p_group_id),
    'received', coalesce((
      select jsonb_agg(private.received_photo_json(uid, d.photo_id) order by d.delivered_at desc)
      from public.deliveries d
      join public.photos p on p.id = d.photo_id
      where d.group_id = p_group_id
        and d.receiver_id = uid
        and p.expired_at is null
        and p.created_at > now() - interval '7 days'
        and not private.is_blocked_between(uid, p.user_id)
    ), '[]'::jsonb)
  );
end;
$$;

-- ─── 檢舉與封鎖 ────────────────────────────────────────────

-- 只能檢舉自己收到的照片。
create function public.report_photo(p_photo_id uuid, p_reason text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  owner uuid;
begin
  select p.user_id into owner
  from public.photos p
  join public.deliveries d on d.photo_id = p.id and d.receiver_id = uid
  where p.id = p_photo_id;

  if owner is null then
    raise exception 'photo_not_found';
  end if;

  insert into public.reports (reporter_id, photo_id, reported_user_id, reason)
  values (uid, p_photo_id, owner, left(coalesce(p_reason, ''), 500));
end;
$$;

-- 全域封鎖；冪等。已收到的照片會從雙方的清單隱藏（資格不退回）。
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
end;
$$;

-- ─── 推播裝置 ──────────────────────────────────────────────

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

-- ─── 權限 ──────────────────────────────────────────────────

revoke execute on function
  public.save_profile(text, boolean),
  public.delete_account(),
  public.create_group(text),
  public.join_group(text),
  public.leave_group(uuid),
  public.my_groups(),
  public.upload_photo(uuid, text, timestamp),
  public.claim_photo(uuid),
  public.group_state(uuid),
  public.report_photo(uuid, text),
  public.block_user(uuid),
  public.register_device(text)
from public, anon;

grant execute on function
  public.save_profile(text, boolean),
  public.delete_account(),
  public.create_group(text),
  public.join_group(text),
  public.leave_group(uuid),
  public.my_groups(),
  public.upload_photo(uuid, text, timestamp),
  public.claim_photo(uuid),
  public.group_state(uuid),
  public.report_photo(uuid, text),
  public.block_user(uuid),
  public.register_device(text)
to authenticated;
