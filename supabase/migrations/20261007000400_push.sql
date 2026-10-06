-- Push notifications. There is exactly one kind: "a new photo is ready".
-- It goes only to members who are waiting (credits > 0 and an empty pool) when someone uploads,
-- at most once per member per group per day (04:00 Asia/Taipei rollover). Nothing ever nudges anyone to upload.

alter table public.group_members add column last_notified_day date;

-- Devices to notify about a new photo, marking each member as notified for today.
-- Only for the notify Edge Function (service_role).
create function public.push_targets(p_photo_id uuid)
returns table (token text, user_id uuid, group_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  photo public.photos;
begin
  select * into photo from public.photos where id = p_photo_id;
  if not found then
    return;
  end if;

  return query
  with waiting as (
    update public.group_members m
    set last_notified_day = public.swapee_day()
    where m.group_id = photo.group_id
      and m.user_id <> photo.user_id
      and m.last_notified_day is distinct from public.swapee_day()
      and private.credits(m.user_id, m.group_id) > 0
      and not private.is_blocked_between(m.user_id, photo.user_id)
      -- This runs asynchronously after the upload, so judge "waiting" as of the photo's arrival:
      -- they had uploaded before it, and haven't received it in the meantime.
      and exists (
        select 1 from public.photos own
        where own.group_id = photo.group_id and own.user_id = m.user_id and own.created_at < photo.created_at
      )
      and not exists (
        select 1 from public.deliveries d where d.photo_id = photo.id and d.receiver_id = m.user_id
      )
      -- They were waiting: before this photo, nothing in the pool was claimable for them.
      and not exists (
        select 1 from public.photos o
        where o.group_id = photo.group_id
          and o.id <> photo.id
          and o.user_id <> m.user_id
          and o.expired_at is null
          and o.created_at > now() - interval '72 hours'
          and not exists (
            select 1 from public.deliveries d where d.photo_id = o.id and d.receiver_id = m.user_id
          )
          and not private.is_blocked_between(m.user_id, o.user_id)
      )
    returning m.user_id, m.group_id
  )
  select d.token, w.user_id, w.group_id
  from waiting w
  join public.devices d on d.user_id = w.user_id;
end;
$$;

-- For tokens APNs reports as invalid.
create function public.remove_device_tokens(p_tokens text[])
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.devices where token = any (p_tokens)
$$;

revoke execute on function
  public.push_targets(uuid),
  public.remove_device_tokens(text[])
from public, anon, authenticated;
grant execute on function
  public.push_targets(uuid),
  public.remove_device_tokens(text[])
to service_role;

-- After an upload, ask the notify Edge Function to send. pg_net sends after commit, without blocking the upload.
-- The function URL and secret live in Vault (see README); without them this does nothing.
create extension if not exists pg_net with schema extensions;

create function private.request_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  url text;
  secret text;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'notify_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'notify_secret';
  if url is null or secret is null then
    return new;
  end if;

  perform net.http_post(
    url := url,
    body := jsonb_build_object('photo_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret)
  );
  return new;
end;
$$;

create trigger photos_after_insert
after insert on public.photos
for each row execute function private.request_push();
