-- Page photos: private bucket, path {user_id}/{uuid}.jpg (lowercase UUIDs).
-- The app uploads the file first, then calls write_entry (or update_entry to swap the photo of an unsent
-- page; the old file is queued for deletion). No update/delete policies: files themselves never change.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('entries', 'entries', false, 4 * 1024 * 1024, array['image/jpeg']);

create function private.entry_path_pattern()
returns text
language sql
immutable
as $$
  select '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
      || '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
$$;

-- Only into your own folder, when there's a photo you could use: tonight's page while writing is open,
-- or a page you haven't sent to anyone. At most 3 files uploaded in the last day that never became a page.
create function private.can_upload_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null or p_name !~ private.entry_path_pattern() or split_part(p_name, '/', 1) <> uid::text then
    return false;
  end if;
  if not (
    (private.can_write(uid) and not private.has_written(uid, private.user_today(uid)))
    or exists (select 1 from public.entries where user_id = uid and sent_at is null)
  ) then
    return false;
  end if;

  if (
    select count(*)
    from storage.objects o
    where o.bucket_id = 'entries'
      and o.name like uid::text || '/%'
      and o.created_at > now() - interval '1 day'
      and not exists (select 1 from public.entries e where e.storage_path = o.name)
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
    select 1 from public.entries e
    where e.storage_path = p_name and private.can_view_entry(e.id)
  )
$$;

grant execute on function
  private.entry_path_pattern(),
  private.can_upload_object(text),
  private.can_read_object(text)
to authenticated;

create policy "entries: upload own file" on storage.objects
for insert to authenticated
with check (bucket_id = 'entries' and private.can_upload_object(name));

-- Signed URLs need this select permission too.
create policy "entries: read visible pages" on storage.objects
for select to authenticated
using (bucket_id = 'entries' and private.can_read_object(name));

-- ─── Avatars ───────────────────────────────────────────────
-- Square JPEGs up to 1 MB at avatars/{user_id}/{uuid}.jpg. Paths are random and only handed out to
-- friends, people with a request between you, and someone who looked you up, so any signed-in user may read.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 1024 * 1024, array['image/jpeg']);

create function private.can_upload_avatar(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
     and p_name ~ private.entry_path_pattern()
     and split_part(p_name, '/', 1) = auth.uid()::text
     and (
       select count(*) from storage.objects o
       where o.bucket_id = 'avatars'
         and o.name like auth.uid()::text || '/%'
         and o.created_at > now() - interval '1 day'
     ) < 10
$$;

grant execute on function private.can_upload_avatar(text) to authenticated;

create policy "avatars: upload own" on storage.objects
for insert to authenticated
with check (bucket_id = 'avatars' and private.can_upload_avatar(name));

create policy "avatars: signed-in users read" on storage.objects
for select to authenticated
using (bucket_id = 'avatars');

-- ─── Cleanup ───────────────────────────────────────────────

-- Files uploaded over a day ago that never became a page or an avatar.
create function private.queue_orphan_files()
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.storage_deletions (path, bucket_id)
  select o.name, o.bucket_id
  from storage.objects o
  where o.created_at < now() - interval '1 day'
    and (
      (o.bucket_id = 'entries' and not exists (select 1 from public.entries e where e.storage_path = o.name))
      or (o.bucket_id = 'avatars' and not exists (select 1 from public.profiles p where p.avatar_path = o.name))
    )
  on conflict do nothing;
$$;

-- These two are only for the cleanup Edge Function (service_role).
create function public.cleanup_pending_paths(p_limit integer default 100)
returns table (bucket_id text, path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.queue_orphan_files();
  return query
    select d.bucket_id, d.path from private.storage_deletions d
    order by d.queued_at
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
