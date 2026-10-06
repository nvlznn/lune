# swapee
swap photos with your friends

One photo a day per group; every photo you send lets you receive one from a friend.

```
Swapee.xcodeproj        iOS app (iOS 17+, SwiftUI, no third-party dependencies)
Swapee/                 app sources (folders sync into the project automatically)
SwapeeTests/            Swift Testing: image processing, decoding, end-to-end client test
Config/                 xcconfigs (backend URL/key), Info.plist, entitlements
supabase/
├── migrations/         schema + RLS, storage, RPCs, push targeting
├── functions/cleanup/  deletes queued Storage files
├── functions/notify/   sends "a new photo is ready" through APNs
└── tests/              pgTAP: the server rule checklist
tests/integration/      Node tests against the real Supabase API (storage, cleanup, push wiring)
```

## Backend (Supabase)

Every write goes through an RPC; clients have no write access to any table. A failed RPC returns an error code in `message` (`already_uploaded_today`, `no_credits`, …); the list is at the top of `…_rpc.sql`, and `APIError` in the app maps them to user-facing text.

### Decisions beyond the plan

- **Expired photos keep their row**: after 7 days `photos.expired_at` is set and the file is deleted, but the row and its `deliveries` stay so credits (sent − received) never shift.
- **When an uploader leaves or deletes their account, everyone who received their photo gets that credit back**, because the photo and its deliveries are deleted.
- **Blocking doesn't refund credits**; received photos are just hidden.
- **Two-step upload**: the app uploads to `photos/{group_id}/{user_id}/{uuid}.jpg` (lowercase UUIDs), then calls `upload_photo`. Storage only accepts the file from a member who hasn't sent a photo to that group today, with at most 3 unregistered files; files never registered are cleaned up after a day.
- **File deletion is queued**: Storage files can't be deleted with SQL, so paths go into `private.storage_deletions` and the `cleanup` function removes them. RLS hides them the moment they're queued.
- **Invite code guessing**: 10 wrong codes per user per hour, then a pause. `join_group` returns an empty array for an unknown code.
- **Push "waiting" is judged as of the photo's arrival**: the notify call runs asynchronously, so a member counts as waiting only if they had uploaded before the new photo, still have credits, have nothing else claimable, and haven't received it already. Max one notification per member per group per day.

### Local development

Needs Docker and the Supabase CLI.

```sh
printf 'CLEANUP_SECRET=local-cleanup-secret\nNOTIFY_SECRET=local-notify-secret\n' > supabase/.env
supabase start -x realtime,imgproxy,mailpit,studio,logflare,vector,supavisor,postgres-meta
supabase test db                                        # pgTAP
(cd tests/integration && npm install && npm test)       # Storage, cleanup, push wiring
```

### Deploying (not yet verified in the cloud)

1. `supabase link`, `supabase db push`
2. Secrets and functions:
   ```sh
   supabase secrets set CLEANUP_SECRET=<random> NOTIFY_SECRET=<random> \
     APNS_KEY_ID=<key id> APNS_TEAM_ID=<team id> APNS_BUNDLE_ID=dev.noky.swapee \
     APNS_ENVIRONMENT=production APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
   supabase functions deploy cleanup
   supabase functions deploy notify
   ```
3. In the SQL editor, give the database the function URLs and secrets, and schedule file cleanup (photo expiry itself already runs hourly via pg_cron):
   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/notify', 'notify_url');
   select vault.create_secret('<NOTIFY_SECRET>', 'notify_secret');
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/cleanup', 'cleanup_url');
   select vault.create_secret('<CLEANUP_SECRET>', 'cleanup_secret');
   select cron.schedule('swapee-cleanup-files', '17 * * * *', $$
     select net.http_post(
       url := (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_url'),
       headers := jsonb_build_object('Authorization', 'Bearer ' ||
         (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_secret'))
     )
   $$);
   ```
4. Auth → Providers → Apple: enable it and add `dev.noky.swapee` as a client ID (native Sign in with Apple only needs the bundle ID).

## iOS app

Open `Swapee.xcodeproj`. Debug builds talk to local Supabase at `127.0.0.1:54321` (simulator only) and show a **Developer Sign-In** button, since Sign in with Apple needs a signed build. Release builds read the URL and publishable key from `Config/Release.xcconfig`.

Before running on a device: set your team under Signing & Capabilities. The entitlements already request Sign in with Apple and Push Notifications.

```sh
xcodebuild test -project Swapee.xcodeproj -scheme Swapee \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'   # end-to-end test needs local Supabase running
```
