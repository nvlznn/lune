-- Captions may span lines, like a note in Reminders. Only the whitespace tidying changes.

create or replace function public.upload_photo(
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
  -- Keep line breaks (at most one blank line in a row); tidy spaces around them and at the ends.
  caption text := nullif(
    btrim(
      regexp_replace(
        regexp_replace(
          regexp_replace(replace(coalesce(p_caption, ''), E'\r\n', E'\n'), '[ \t]+', ' ', 'g'),
          ' ?\n ?', E'\n', 'g'),
        '\n{3,}', E'\n\n', 'g'),
      E' \n\t'),
    '');
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

