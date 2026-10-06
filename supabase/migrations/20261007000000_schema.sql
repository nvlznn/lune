-- Swapee 資料模型。所有寫入都走 RPC（見 rpc migration），客戶端只能透過 RLS 讀。

create schema if not exists private;
grant usage on schema private to authenticated;
-- private 的函式預設誰都不能執行，需要時再個別 grant。
alter default privileges in schema private revoke execute on functions from public;

-- 換日：全站以 Asia/Taipei 凌晨 04:00 為一天的開始。
create function public.swapee_day(ts timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select ((ts at time zone 'Asia/Taipei') - interval '4 hours')::date
$$;

-- ─── 資料表 ────────────────────────────────────────────────

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 30),
  terms_accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 40),
  -- 擁有者離開時由 private.on_member_removed 轉移，所以不 cascade。
  owner_id uuid not null references public.profiles (id),
  -- 6 碼，不含 0/O、1/I。
  invite_code text not null unique check (invite_code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user_id_idx on public.group_members (user_id);

create table public.photos (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  user_id uuid not null,
  -- 由 upload_photo 以 swapee_day() 算出，客戶端無法指定。
  day date not null,
  storage_path text not null unique,
  -- EXIF DateTimeOriginal，拍攝者當地時間、不帶時區；讀不到為 null。絕不存 GPS。
  taken_at timestamp,
  created_at timestamptz not null default now(),
  -- 超過 7 天：檔案刪除、列保留，讓 credits（上傳數 − 已收數）不會因過期而變動。
  expired_at timestamptz,
  unique (group_id, user_id, day),
  -- 離開群組（或刪除帳號）時，該成員在此群組的照片跟著刪除。
  foreign key (group_id, user_id) references public.group_members (group_id, user_id) on delete cascade
);
create index photos_group_created_idx on public.photos (group_id, created_at desc);

create table public.deliveries (
  receiver_id uuid not null,
  group_id uuid not null,
  photo_id uuid not null references public.photos (id) on delete cascade,
  delivered_at timestamptz not null default now(),
  primary key (receiver_id, photo_id),
  foreign key (group_id, receiver_id) references public.group_members (group_id, user_id) on delete cascade
);
create index deliveries_photo_id_idx on public.deliveries (photo_id);
create index deliveries_group_receiver_idx on public.deliveries (group_id, receiver_id);

-- 全域封鎖：在所有群組互相排除。
create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_id_idx on public.blocks (blocked_id);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles (id) on delete set null,
  photo_id uuid references public.photos (id) on delete set null,
  -- 照片被刪後仍要知道是誰被檢舉。
  reported_user_id uuid references public.profiles (id) on delete set null,
  reason text not null check (char_length(reason) <= 500),
  created_at timestamptz not null default now()
);

create table public.devices (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index devices_user_id_idx on public.devices (user_id);

-- 待刪除的 Storage 檔案。Storage 檔案只能透過 Storage API 刪，
-- 由 cleanup Edge Function 消化；RLS 讓這些檔案在排入佇列的當下就讀不到。
create table private.storage_deletions (
  path text primary key,
  queued_at timestamptz not null default now()
);

-- ─── 成員異動 ──────────────────────────────────────────────

-- 成員離開後：沒人了就刪群組；擁有者離開則由最早加入的成員接手。
create function private.on_member_removed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  next_owner uuid;
begin
  -- 群組本身正在被刪除（cascade）時不用處理。
  if not exists (select 1 from public.groups where id = old.group_id) then
    return old;
  end if;

  select user_id into next_owner
  from public.group_members
  where group_id = old.group_id
  order by joined_at, user_id
  limit 1;

  if next_owner is null then
    delete from public.groups where id = old.group_id;
  else
    update public.groups
    set owner_id = next_owner
    where id = old.group_id and owner_id = old.user_id;
  end if;

  return old;
end;
$$;

create trigger group_members_after_delete
after delete on public.group_members
for each row execute function private.on_member_removed();

-- 刪除帳號時，先逐一離開群組，讓擁有者轉移在 profiles 消失之前完成。
create function private.on_profile_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.group_members where user_id = old.id;
  return old;
end;
$$;

create trigger profiles_before_delete
before delete on public.profiles
for each row execute function private.on_profile_delete();

-- 照片列被刪除時，把檔案排入刪除佇列。
create function private.on_photo_deleted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.storage_deletions (path) values (old.storage_path)
  on conflict do nothing;
  return old;
end;
$$;

create trigger photos_after_delete
after delete on public.photos
for each row execute function private.on_photo_deleted();

-- ─── RLS 輔助函式 ──────────────────────────────────────────
-- security definer 以避免 group_members 的 policy 遞迴。

create function private.is_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = auth.uid()
  )
$$;

create function private.shares_group(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members a
    join public.group_members b on b.group_id = a.group_id
    where a.user_id = auth.uid() and b.user_id = p_user_id
  )
$$;

create function private.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  )
$$;

-- 照片主人，或已被配給、未過期、雙方未封鎖的接收者。
create function private.can_view_photo(p_photo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.photos p
    where p.id = p_photo_id
      and p.expired_at is null
      and (
        p.user_id = auth.uid()
        or (
          exists (
            select 1 from public.deliveries d
            where d.photo_id = p.id and d.receiver_id = auth.uid()
          )
          and not private.is_blocked_between(auth.uid(), p.user_id)
        )
      )
  )
$$;

grant execute on function
  private.is_member(uuid),
  private.shares_group(uuid),
  private.is_blocked_between(uuid, uuid),
  private.can_view_photo(uuid)
to authenticated;

-- ─── RLS ───────────────────────────────────────────────────
-- 沒有 insert/update/delete policy：寫入一律經由 RPC。

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.photos enable row level security;
alter table public.deliveries enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;
alter table public.devices enable row level security;

create policy "profiles: self and group-mates" on public.profiles
for select to authenticated
using (id = (select auth.uid()) or private.shares_group(id));

create policy "groups: members" on public.groups
for select to authenticated
using (private.is_member(id));

create policy "group_members: members of the same group" on public.group_members
for select to authenticated
using (private.is_member(group_id));

create policy "photos: owner or permitted receiver" on public.photos
for select to authenticated
using (private.can_view_photo(id));

create policy "deliveries: own" on public.deliveries
for select to authenticated
using (receiver_id = (select auth.uid()));

create policy "blocks: own" on public.blocks
for select to authenticated
using (blocker_id = (select auth.uid()));

-- anon 不需要任何資料表權限。
revoke all on all tables in schema public from anon;
