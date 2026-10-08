// Sets up the App Review account: an email/password user that is always open, with three friends
// (Mia, Leo, Ava) who each sent it a letter. Their letters move to the reviewer's day automatically.
// Safe to run again, e.g. after the reviewer tried deleting the account or blocking a friend.
//
//   cd scripts/review-account && npm install
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<service role key> \
//   REVIEW_EMAIL=review@noky.dev REVIEW_PASSWORD=<password> npm run setup
//
// The service role key bypasses every rule: keep it out of the app and out of git.

import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, REVIEW_EMAIL, REVIEW_PASSWORD } = process.env;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !REVIEW_EMAIL || !REVIEW_PASSWORD) {
  console.error("Set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, REVIEW_EMAIL and REVIEW_PASSWORD.");
  process.exit(1);
}
if (REVIEW_PASSWORD.length < 12) {
  console.error("Use a REVIEW_PASSWORD of at least 12 characters.");
  process.exit(1);
}

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const asset = (name) => readFileSync(new URL(`./assets/${name}.jpg`, import.meta.url));

const friends = [
  {
    key: "mia",
    name: "Mia",
    username: "mia.moonlit",
    text: "Watched the sky turn orange on the walk home. The moon was out before the sun was gone.",
  },
  {
    key: "leo",
    name: "Leo",
    username: "leo.teatime",
    text: "Made too much tea and drank all of it anyway. A quiet night, which is what I needed.",
  },
  {
    key: "ava",
    name: "Ava",
    username: "ava.latetrain",
    text: "Late train, city lights, headphones on. Tired but happy.",
  },
];

/** Creates the user, or finds it and resets its password. Returns its id. */
async function ensureUser(email, password) {
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (!created.error) return created.data.user.id;

  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const user = data.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
    if (user) {
      const updated = await admin.auth.admin.updateUserById(user.id, { password, email_confirm: true });
      if (updated.error) throw updated.error;
      return user.id;
    }
    if (data.users.length < 1000) throw created.error;
  }
}

async function upload(bucket, userId, file) {
  const path = `${userId}/${randomUUID()}.jpg`;
  const { error } = await admin.storage.from(bucket).upload(path, file, { contentType: "image/jpeg", upsert: false });
  if (error) throw error;
  return path;
}

const reviewerId = await ensureUser(REVIEW_EMAIL, REVIEW_PASSWORD);

const cast = [];
for (const friend of friends) {
  // The friends never sign in; their passwords are random and thrown away.
  const [local, domain] = REVIEW_EMAIL.split("@");
  const userId = await ensureUser(`${local}+${friend.key}@${domain}`, randomUUID());
  cast.push({
    user_id: userId,
    name: friend.name,
    username: friend.username,
    avatar_path: await upload("avatars", userId, asset(`avatar-${friend.key}`)),
    storage_path: await upload("entries", userId, asset(`photo-${friend.key}`)),
    text: friend.text,
  });
}

const { error } = await admin.rpc("setup_review_account", {
  p_reviewer: reviewerId,
  p_name: "App Review",
  p_username: "lune.review",
  p_friends: cast,
});
if (error) throw error;

console.log(`Review account ready: ${REVIEW_EMAIL}`);
console.log(`Friends: ${friends.map((f) => `${f.name} (@${f.username})`).join(", ")}`);
console.log("In the app, hold the moon on the sign-in screen for two seconds to sign in with email.");
