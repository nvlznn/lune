# Lune

A nightly diary you send to friends like letters. One page a day — a photo and a few words — sent to the friends you choose, and you read what they sent you after writing your own.

```
Lune.xcodeproj          iOS app (iOS 17+, SwiftUI, no third-party dependencies)
Lune/                   app sources (folders sync into the project automatically)
LuneTests/              Swift Testing: image processing, decoding, end-to-end client test
Config/                 xcconfigs (backend URL/key), Info.plist, entitlements
Lune.storekit           local StoreKit config for Lune Premium (used by the Lune scheme)
design/app-icon/        moon icon (white circle with two eyes on black) and its generator; same drawing as MoonView
supabase/
├── migrations/         schema + RLS, storage, RPCs, push
├── functions/cleanup/  deletes queued Storage files
├── functions/notify/   sends pushes through APNs
└── tests/              pgTAP
tests/integration/      Node tests against the real Supabase API (storage, cleanup, push wiring)
```

## How it works

- **One page per person per day**: one photo and up to 500 characters (line breaks kept).
- **Days are local and start at 20:00**: each person's day runs 20:00–20:00 in their own time zone (the app reports it). Pages are written 20:00–04:00 (the server accepts them until 04:10, so one started before closing can still be sent); the whole night belongs to that day.
- **Letters**: a page goes to all friends by default, to picked friends or groups, or to nobody. The app expands "all friends" and groups into a list of ids and confirms it before sending; the server skips anyone who isn't a friend. Sending is immediate and final: a page sent to anyone can't be edited or deleted, and there are no read receipts. The writer sees who they sent it to; recipients don't see who else got it. More friends can be added until the day ends; friends made later don't get earlier pages.
- **Pages kept to yourself** can be edited (text and photo) or deleted any time, and sent later the same day, after which they're final.
- **Write, then read**: you open a day's letters only after writing your own page for that day (sent or not). Until then they show as locked cards with the sender's name. A day you didn't write stays locked.
- **Letters last one day**: everyone's letters for a day disappear at 20:00 the next evening.
- **Groups**: your own named lists of friends (up to 100), only visible to you. Ending a friendship removes that person from your groups.
- **Your diary is permanent**: free users see their own last 30 days in the app; **Lune Premium** (US$0.99/month or US$7.99/year) shows the whole diary. Nothing is deleted for not paying, and export (a zip of photos + Markdown) is always free.
- **Profiles**: at first sign-in you add a photo (optional), a name and a username; all three can be changed later in Account. Usernames follow Instagram's rules — 1–30 of a–z, 0–9, `.` and `_`, no leading, trailing or doubled period — and are unique regardless of case. Sign in with Apple doesn't share a photo, so without one the app shows your initials.
- **Friends**: mutual, up to 1,000. Type a friend's exact username, check who it is, and send a request they accept (or become friends at once if they already asked you). There's no browsing or partial search. Blocking also ends the friendship and hides you from their lookups.
- **Avatars**: square 512 px JPEGs without metadata in the `avatars` bucket at `{user_id}/{uuid}.jpg`. Paths are random and only handed out to friends, people with a request between you, and someone who looked up your username. Replaced avatars are deleted by cleanup.
- **Pushes**: one when your diary opens ("Tonight's page is open — Alice and Bob wrote to you", sent 20:00–22:00 local, once per night), one when a friend sends you a page for your current day, and friend requests. Nothing nudges anyone to write.
- **Two-step upload**: the app uploads to `entries/{user_id}/{uuid}.jpg` (lowercase UUIDs), then calls `write_entry` (or `update_entry` to swap an unsent page's photo; the old file is deleted). Storage only accepts files while you can still write tonight's page or have an unsent page, with at most 3 unused files a day; unused files are cleaned up after a day.
- **File deletion is queued**: Storage files can't be deleted with SQL, so paths go into `private.storage_deletions` and the `cleanup` function removes them.

Every write goes through an RPC; clients have no write access to any table. A failed RPC returns an error code in `message` (`closed`, `already_written`, …); the list is at the top of `…_rpc.sql`, and `APIError` in the app maps them to user-facing text.

## Local development

Needs Docker and the Supabase CLI.

```sh
printf 'CLEANUP_SECRET=local-cleanup-secret\nNOTIFY_SECRET=local-notify-secret\n' > supabase/.env
supabase start -x realtime,imgproxy,mailpit,studio,logflare,vector,supavisor,postgres-meta
supabase test db                                        # pgTAP
(cd tests/integration && npm install && npm test)       # Storage, cleanup, push wiring
```

Tests put each test user in an `Etc/GMT±N` zone where it's currently 22:00 (open) or 12:00 (closed), so they pass at any time of day.

## Deploying (not yet verified in the cloud)

1. `supabase link`, `supabase db push`
2. Secrets and functions:
   ```sh
   supabase secrets set CLEANUP_SECRET=<random> NOTIFY_SECRET=<random> \
     APNS_KEY_ID=<key id> APNS_TEAM_ID=<team id> APNS_BUNDLE_ID=dev.noky.lune \
     APNS_ENVIRONMENT=production APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
   supabase functions deploy cleanup
   supabase functions deploy notify
   ```
3. In the SQL editor, give the database the function URLs and secrets, and schedule file cleanup (the opening push is already scheduled every 15 minutes by the push migration):
   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/notify', 'notify_url');
   select vault.create_secret('<NOTIFY_SECRET>', 'notify_secret');
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/cleanup', 'cleanup_url');
   select vault.create_secret('<CLEANUP_SECRET>', 'cleanup_secret');
   select cron.schedule('lune-cleanup-files', '17 * * * *', $$
     select net.http_post(
       url := (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_url'),
       headers := jsonb_build_object('Authorization', 'Bearer ' ||
         (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_secret'))
     )
   $$);
   ```
4. Auth → Providers → Apple: enable it and add `dev.noky.lune` as a client ID.
5. App Store Connect: create the auto-renewable subscriptions `dev.noky.lune.premium.monthly` and `dev.noky.lune.premium.yearly` in one group ("Lune Premium").

## iOS app

Open `Lune.xcodeproj`. Debug builds talk to local Supabase (`127.0.0.1:54321` in the simulator; on a device, set `DEV_SERVER_HOST` in `Config/Local.xcconfig`) and show a **Developer Sign-In** button. Release builds read the URL and publishable key from `Config/Release.xcconfig`. Running the Lune scheme uses `Lune.storekit`, so Lune Premium can be bought in the simulator without App Store Connect.

```sh
xcodebuild test -project Lune.xcodeproj -scheme Lune \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'   # end-to-end test needs local Supabase running
```
