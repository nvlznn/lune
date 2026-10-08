-- Push notifications. Three kinds, and nothing that nudges anyone to write:
--   * when the diary opens (once per night, 20:00–22:00 local): "Tonight's page is open — Alice and Bob wrote to you";
--   * a friend sent you a page, right away (if it's for your current day);
--   * someone sent you a friend request.
-- The database decides who to notify; the notify Edge Function talks to APNs.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- Calls the notify Edge Function. The URL and secret live in Vault (see README); without them this does nothing.
create function private.call_notify(p_body jsonb)
returns void
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
    return;
  end if;
  -- pg_net sends after commit, without blocking the caller.
  perform net.http_post(
    url := url,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret)
  );
end;
$$;

-- One call per page sent, naming the new recipients.
create function private.on_letters_sent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.call_notify(jsonb_build_object(
    'letter', jsonb_build_object('entry_id', n.entry_id, 'recipient_ids', jsonb_agg(n.user_id))
  ))
  from new_rows n
  group by n.entry_id;
  return null;
end;
$$;

create trigger entry_recipients_after_insert
after insert on public.entry_recipients
referencing new table as new_rows
for each statement execute function private.on_letters_sent();

create function private.on_friend_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.call_notify(jsonb_build_object('request', jsonb_build_object('from_id', new.from_id, 'to_id', new.to_id)));
  return new;
end;
$$;

create trigger friend_requests_after_insert
after insert on public.friend_requests
for each row execute function private.on_friend_request();

-- Every 15 minutes, let the notify function send opening pushes to whoever's diary just opened.
select cron.schedule('lune-opening-push', '*/15 * * * *', $$ select private.call_notify('{"opening": true}'::jsonb) $$);

-- ─── Targets (service_role only) ───────────────────────────

-- A page was sent: the new recipients it still counts as a letter for (friends, no block, their day).
create function public.push_targets_letter(p_entry_id uuid, p_recipient_ids uuid[])
returns table (token text, user_id uuid, writer_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.token, d.user_id, w.display_name
  from public.entry_recipients r
  join public.entries e on e.id = r.entry_id
  join public.profiles w on w.id = e.user_id
  join public.devices d on d.user_id = r.user_id
  where r.entry_id = p_entry_id
    and r.user_id = any (p_recipient_ids)
    and private.is_letter_to(e.id, r.user_id)
$$;

create function public.push_targets_request(p_from_id uuid, p_to_id uuid)
returns table (token text, requester_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.token, p.display_name
  from public.friend_requests r
  join public.profiles p on p.id = r.from_id
  join public.devices d on d.user_id = r.to_id
  where r.from_id = p_from_id and r.to_id = p_to_id
$$;

-- People whose diary opened in the last two hours and who haven't had tonight's push yet.
-- Marks them so it's sent once per night. writers = friends who already sent them tonight's page, earliest first.
create function public.push_targets_opening()
returns table (token text, user_id uuid, writers text[])
language sql
volatile
security definer
set search_path = ''
as $$
  with due as (
    select p.id, private.user_today(p.id) as day
    from public.profiles p
    where (now() at time zone p.time_zone)::time between time '20:00' and time '22:00'
      and exists (select 1 from public.devices d where d.user_id = p.id)
      and not exists (
        select 1 from private.window_pushes w where w.user_id = p.id and w.day = private.user_today(p.id)
      )
  ),
  marked as (
    insert into private.window_pushes (user_id, day)
    select id, day from due
    on conflict do nothing
    returning user_id, day
  )
  select d.token, m.user_id, array(
    select wp.display_name
    from public.entry_recipients r
    join public.entries e on e.id = r.entry_id
    join public.profiles wp on wp.id = e.user_id
    where r.user_id = m.user_id
      and private.is_letter_to(e.id, m.user_id)
    order by r.sent_at
  )
  from marked m
  join public.devices d on d.user_id = m.user_id
$$;

-- Tokens APNs reports as invalid.
create function public.remove_device_tokens(p_tokens text[])
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.devices where token = any (p_tokens)
$$;

revoke execute on function
  public.push_targets_letter(uuid, uuid[]),
  public.push_targets_request(uuid, uuid),
  public.push_targets_opening(),
  public.remove_device_tokens(text[])
from public, anon, authenticated;
grant execute on function
  public.push_targets_letter(uuid, uuid[]),
  public.push_targets_request(uuid, uuid),
  public.push_targets_opening(),
  public.remove_device_tokens(text[])
to service_role;
