-- 照片檔案：私有 bucket，路徑 {group_id}/{user_id}/{photo_uuid}.jpg（UUID 一律小寫）。
-- 客戶端先上傳檔案，再呼叫 upload_photo 登記；沒有 update/delete policy，檔案傳了就不能改。

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 4 * 1024 * 1024, array['image/jpeg']);

create function private.photo_path_pattern()
returns text
language sql
immutable
as $$
  select '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
      || '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
      || '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
$$;

-- 只能傳到自己的資料夾、自己所在的群組、今天在該群組還沒傳過。
create function private.can_upload_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  parts text[];
  gid uuid;
begin
  if uid is null or p_name !~ private.photo_path_pattern() then
    return false;
  end if;

  parts := string_to_array(p_name, '/');
  if parts[2] <> uid::text then
    return false;
  end if;
  gid := parts[1]::uuid;

  if not exists (
    select 1 from public.group_members where group_id = gid and user_id = uid
  ) then
    return false;
  end if;

  if exists (
    select 1 from public.photos
    where group_id = gid and user_id = uid and day = public.swapee_day()
  ) then
    return false;
  end if;

  -- 上傳了卻沒登記的檔案（例如傳送中斷後重試）最多 3 個，避免拿 bucket 當免費空間。
  if (
    select count(*)
    from storage.objects o
    where o.bucket_id = 'photos'
      and o.name like gid::text || '/' || uid::text || '/%'
      and o.created_at > now() - interval '1 day'
      and not exists (select 1 from public.photos p where p.storage_path = o.name)
  ) >= 3 then
    return false;
  end if;

  return true;
end;
$$;

create function private.can_read_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.photos p
    where p.storage_path = p_name and private.can_view_photo(p.id)
  )
$$;

grant execute on function
  private.photo_path_pattern(),
  private.can_upload_object(text),
  private.can_read_object(text)
to authenticated;

create policy "photos: upload own file" on storage.objects
for insert to authenticated
with check (bucket_id = 'photos' and private.can_upload_object(name));

-- 簽名網址也需要這個 select 權限才能產生。
create policy "photos: owner or permitted receiver" on storage.objects
for select to authenticated
using (bucket_id = 'photos' and private.can_read_object(name));

-- ─── 清除 ──────────────────────────────────────────────────

-- 超過 7 天的照片：標記 expired_at（RLS 立刻讀不到），檔案排入刪除佇列。
-- 同時清掉上傳超過一天卻沒登記的孤兒檔。
create function private.expire_old_photos()
returns void
language sql
security definer
set search_path = ''
as $$
  with expired as (
    update public.photos
    set expired_at = now()
    where expired_at is null and created_at < now() - interval '7 days'
    returning storage_path
  )
  insert into private.storage_deletions (path)
  select storage_path from expired
  on conflict do nothing;

  insert into private.storage_deletions (path)
  select o.name
  from storage.objects o
  where o.bucket_id = 'photos'
    and o.created_at < now() - interval '1 day'
    and not exists (select 1 from public.photos p where p.storage_path = o.name)
  on conflict do nothing;
$$;

-- 以下兩個只給 cleanup Edge Function（service_role）用。
create function public.cleanup_pending_paths(p_limit integer default 100)
returns setof text
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.expire_old_photos();
  return query
    select path from private.storage_deletions
    order by queued_at
    limit p_limit;
end;
$$;

create function public.cleanup_mark_done(p_paths text[])
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.storage_deletions where path = any (p_paths)
$$;

revoke execute on function
  public.cleanup_pending_paths(integer),
  public.cleanup_mark_done(text[])
from public, anon, authenticated;
grant execute on function
  public.cleanup_pending_paths(integer),
  public.cleanup_mark_done(text[])
to service_role;

-- 每小時把過期照片標記起來；即使檔案還沒被 Edge Function 刪掉，也已經讀不到。
create extension if not exists pg_cron;
select cron.schedule('swapee-expire-photos', '7 * * * *', 'select private.expire_old_photos()');
