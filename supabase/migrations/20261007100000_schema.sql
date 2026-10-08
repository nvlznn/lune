-- Lune: a nightly exchange diary with friends.
-- One page (photo + text) per person per day; the diary opens 20:00–04:00 in each person's time zone.
-- Every write goes through an RPC (see the rpc migration); clients only read through RLS.

create schema if not exists private;
grant usage on schema private to authenticated;
-- Functions in private are callable only where granted explicitly.
alter default privileges in schema private revoke execute on functions from public;

-- ─── Tables ────────────────────────────────────────────────

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 30),
  -- Instagram-style handle friends use to find you: 1–30 of a–z, 0–9, "." and "_",
  -- no leading, trailing or doubled period. Stored lowercase. Null until chosen at first sign-in.
  username text unique check (
    username ~ '^[a-z0-9._]{1,30}$' and username !~ '(^\.|\.$|\.\.)'
  ),
  -- {user_id}/{uuid}.jpg in the avatars bucket; null shows initials.
  avatar_path text unique,
  -- IANA name reported by the app; decides this person's days and night window.
  time_zone text not null default 'UTC',
  terms_accepted_at timestamptz,
  created_at timestamptz not null default now()
);

-- Mutual friendships, stored once with the smaller id first.
create table public.friendships (
  user_a uuid not null references public.profiles (id) on delete cascade,
  user_b uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);
create index friendships_user_b_idx on public.friendships (user_b);

create table public.friend_requests (
  from_id uuid not null references public.profiles (id) on delete cascade,
  to_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_id, to_id),
  check (from_id <> to_id)
);
create index friend_requests_to_id_idx on public.friend_requests (to_id);

-- One page per person per day: a photo and the day's text.
create table public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- The writer's day (04:00 rollover in their time zone), set by write_entry.
  day date not null,
  storage_path text not null unique,
  text text not null check (char_length(text) between 1 and 500),
  -- EXIF DateTimeOriginal: the photographer's local time, no offset; null when unknown. Never GPS.
  taken_at timestamp,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  unique (user_id, day)
);
create index entries_day_idx on public.entries (day);

-- Who saw which page, and when (shown to the writer as "Seen by").
create table public.entry_views (
  viewer_id uuid not null references public.profiles (id) on delete cascade,
  entry_id uuid not null references public.entries (id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (viewer_id, entry_id)
);
create index entry_views_entry_id_idx on public.entry_views (entry_id);

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
  entry_id uuid references public.entries (id) on delete set null,
  -- Kept so moderators know who was reported after the page is gone.
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

-- Storage files waiting to be deleted through the Storage API by the cleanup function.
create table private.storage_deletions (
  path text primary key,
  bucket_id text not null default 'entries',
  queued_at timestamptz not null default now()
);

-- Usernames looked up that didn't exist, for rate limiting.
create table private.username_lookup_failures (
  user_id uuid not null references public.profiles (id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index username_lookup_failures_user_idx on private.username_lookup_failures (user_id, attempted_at);

-- Who already got tonight's "the diary is open" push.
create table private.window_pushes (
  user_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  primary key (user_id, day)
);

-- A deleted page's photo goes into the deletion queue.
create function private.on_entry_deleted()
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

create trigger entries_after_delete
after delete on public.entries
for each row execute function private.on_entry_deleted();

-- A replaced or deleted avatar goes into the deletion queue.
create function private.on_avatar_replaced()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.avatar_path is not null and (tg_op = 'DELETE' or new.avatar_path is distinct from old.avatar_path) then
    insert into private.storage_deletions (path, bucket_id) values (old.avatar_path, 'avatars')
    on conflict do nothing;
  end if;
  return coalesce(new, old);
end;
$$;

create trigger profiles_avatar_replaced
after update of avatar_path or delete on public.profiles
for each row execute function private.on_avatar_replaced();

-- ─── Time ──────────────────────────────────────────────────
-- A day runs from 04:00 to 04:00 local time; the diary is open from 20:00 to 04:00.

create function private.day_at(p_time_zone text, p_at timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select ((p_at at time zone p_time_zone) - interval '4 hours')::date
$$;

create function private.is_open_at(p_time_zone text, p_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (p_at at time zone p_time_zone)::time >= time '20:00'
      or (p_at at time zone p_time_zone)::time < time '04:00'
$$;

create function private.time_zone_of(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select time_zone from public.profiles where id = p_user_id), 'UTC')
$$;

create function private.user_today(p_user_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select private.day_at(private.time_zone_of(p_user_id), now())
$$;

create function private.is_open(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_open_at(private.time_zone_of(p_user_id), now())
$$;

-- ─── Relationships ─────────────────────────────────────────

create function private.are_friends(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.friendships
    where user_a = least(a, b) and user_b = greatest(a, b)
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
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  )
$$;

-- Your own pages always. A friend's page only while your diary is open, for your today or
-- yesterday, if you wrote that day too, and neither of you blocked the other.
create function private.can_view_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.entries e
    where e.id = p_entry_id
      and (
        e.user_id = auth.uid()
        or (
          private.are_friends(auth.uid(), e.user_id)
          and not private.is_blocked_between(auth.uid(), e.user_id)
          and private.is_open(auth.uid())
          and e.day in (private.user_today(auth.uid()), private.user_today(auth.uid()) - 1)
          and exists (
            select 1 from public.entries mine where mine.user_id = auth.uid() and mine.day = e.day
          )
        )
      )
  )
$$;

grant execute on function
  private.day_at(text, timestamptz),
  private.is_open_at(text, timestamptz),
  private.time_zone_of(uuid),
  private.user_today(uuid),
  private.is_open(uuid),
  private.are_friends(uuid, uuid),
  private.is_blocked_between(uuid, uuid),
  private.can_view_entry(uuid)
to authenticated;

-- ─── RLS ───────────────────────────────────────────────────
-- No insert/update/delete policies: writes go through RPCs.

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.friend_requests enable row level security;
alter table public.entries enable row level security;
alter table public.entry_views enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;
alter table public.devices enable row level security;

create policy "profiles: self and friends" on public.profiles
for select to authenticated
using (id = (select auth.uid()) or private.are_friends((select auth.uid()), id));

create policy "friendships: own" on public.friendships
for select to authenticated
using ((select auth.uid()) in (user_a, user_b));

create policy "friend_requests: own" on public.friend_requests
for select to authenticated
using ((select auth.uid()) in (from_id, to_id));

create policy "entries: own or visible friend pages" on public.entries
for select to authenticated
using (private.can_view_entry(id));

create policy "entry_views: own" on public.entry_views
for select to authenticated
using (viewer_id = (select auth.uid()));

create policy "blocks: own" on public.blocks
for select to authenticated
using (blocker_id = (select auth.uid()));

revoke all on all tables in schema public from anon;
