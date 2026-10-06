-- Captions: one optional line written when sending, fixed afterwards like the photo itself.
-- Seen by: the sender can see who received today's photo and when (a delivery is made when the receiver opens the group).

alter table public.photos
  add column caption text check (caption is null or char_length(caption) between 1 and 140);

-- upload_photo gains p_caption; a new parameter means a new signature, so replace the old one.
drop function public.upload_photo(uuid, text, timestamp);

create function public.upload_photo(
  p_group_id uuid,
  p_storage_path text,
  p_taken_at timestamp default null,
  p_caption text default null
)
returns public.photos
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := private.current_user_with_profile();
  caption text := nullif(btrim(regexp_replace(coalesce(p_caption, ''), '\s+', ' ', 'g')), '');
  result public.photos;
begin
  perform private.require_member(uid, p_group_id);

  if p_storage_path !~ private.photo_path_pattern()
     or split_part(p_storage_path, '/', 1) <> p_group_id::text
     or split_part(p_storage_path, '/', 2) <> uid::text then
    raise exception 'invalid_path';
  end if;

  if char_length(caption) > 140 then
    raise exception 'caption_too_long';
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
    insert into public.photos (group_id, user_id, day, storage_path, taken_at, caption)
    values (
      p_group_id,
      uid,
      public.swapee_day(),
      p_storage_path,
      -- A capture time more than a day in the future is treated as unknown.
      case when p_taken_at <= (now() at time zone 'UTC') + interval '1 day' then p_taken_at end,
      caption
    )
    returning * into result;
  exception when unique_violation then
    raise exception 'already_uploaded_today';
  end;

  return result;
end;
$$;

revoke execute on function public.upload_photo(uuid, text, timestamp, text) from public, anon;
grant execute on function public.upload_photo(uuid, text, timestamp, text) to authenticated;

create or replace function private.received_photo_json(p_receiver_id uuid, p_photo_id uuid)
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
    'caption', p.caption,
    'uploaded_at', p.created_at,
    'delivered_at', d.delivered_at
  )
  from public.photos p
  join public.profiles pr on pr.id = p.user_id
  join public.deliveries d on d.photo_id = p.id and d.receiver_id = p_receiver_id
  where p.id = p_photo_id
$$;

create or replace function public.group_state(p_group_id uuid)
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
    'caption', p.caption,
    'uploaded_at', p.created_at,
    -- Who has received it, earliest first. Blocked people are left out either way.
    'seen_by', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', d.receiver_id, 'name', pr.display_name, 'seen_at', d.delivered_at)
                       order by d.delivered_at)
      from public.deliveries d
      join public.profiles pr on pr.id = d.receiver_id
      where d.photo_id = p.id and not private.is_blocked_between(uid, d.receiver_id)
    ), '[]'::jsonb)
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
