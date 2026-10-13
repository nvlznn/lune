-- Letters no longer need you to write first. A page written on night D arrives at the reader's 20:00
-- on D+1 and can be read as soon as it arrives, until the night ends at 05:00. There are no locked
-- letters any more: tonight() lists what has arrived, and can_view_entry only checks the letter itself.
--
-- The night now runs 20:00–05:00 (it was 20:00–04:00): the diary is open, pages can be written and
-- letters can be read in that window. The 10 minutes' grace for a page started before closing now
-- runs to 05:10 (can_write_at is built on is_open_at).

create or replace function private.is_open_at(p_time_zone text, p_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (p_at at time zone p_time_zone)::time >= time '20:00'
      or (p_at at time zone p_time_zone)::time < time '05:00'
$$;

create or replace function private.can_view_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.entries e
    where e.id = p_entry_id
      and (e.user_id = auth.uid() or private.is_letter_to(e.id, auth.uid()))
  )
$$;

create or replace function public.tonight()
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
begin
  return jsonb_build_object(
    'today', today,
    'open', open,
    -- Writing closes at 05:00 and reopens at 20:00 on the same local date.
    'opens_at', case when open then null else (local_now::date + time '20:00') at time zone tz end,
    -- The review account never closes.
    'closes_at', case when open and not private.is_reviewer(uid) then ((today + 1) + time '05:00') at time zone tz end,
    -- When the next day starts. Last night's letters disappear earlier, when the night ends (closes_at).
    'ends_at', ((today + 1) + time '20:00') at time zone tz,
    'mine', (select private.entry_json(e.id, uid) from public.entries e where e.user_id = uid and e.day = today),
    'letters', coalesce((
      select jsonb_agg(private.entry_json(e.id, uid) order by r.sent_at desc, e.id)
      from public.entry_recipients r
      join public.entries e on e.id = r.entry_id
      where r.user_id = uid and private.is_letter_to(e.id, uid)
    ), '[]'::jsonb)
  );
end;
$$;
