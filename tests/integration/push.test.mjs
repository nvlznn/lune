// Checks the push wiring end to end, short of APNs: an upload fires the photos trigger,
// pg_net calls the notify Edge Function, and push_targets marks the waiting member as notified.
// Locally there's no APNs key, so the function stops right before sending.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const env = Object.fromEntries(
  execFileSync("supabase", ["status", "-o", "env"], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.match(/^([A-Z_]+)="?(.*?)"?$/))
    .filter(Boolean)
    .map((m) => [m[1], m[2]]),
);
const admin = createClient(env.API_URL, env.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const NOTIFY_SECRET = process.env.NOTIFY_SECRET ?? "local-notify-secret";
const JPEG = Buffer.from("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=", "base64");

function psql(sql) {
  return execFileSync("docker", ["exec", "-i", "supabase_db_swapee", "psql", "-U", "postgres", "-d", "postgres", "-Atq"], {
    input: sql,
    encoding: "utf8",
  }).trim();
}

async function signUp(name) {
  const email = `${name}-${randomUUID()}@integration.test`;
  const password = randomUUID();
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(error);
  const client = createClient(env.API_URL, env.ANON_KEY, { auth: { persistSession: false } });
  assert.ifError((await client.auth.signInWithPassword({ email, password })).error);
  assert.ifError((await client.rpc("save_profile", { p_display_name: name, p_accept_terms: true })).error);
  return { id: data.user.id, client };
}

async function upload(user, groupId) {
  const path = `${groupId}/${user.id}/${randomUUID()}.jpg`;
  assert.ifError((await user.client.storage.from("photos").upload(path, JPEG, { contentType: "image/jpeg" })).error);
  const { data, error } = await user.client.rpc("upload_photo", { p_group_id: groupId, p_storage_path: path });
  assert.ifError(error);
  return data;
}

async function waitFor(check, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

before(() => {
  // The trigger reads the function URL and secret from Vault; the database reaches the API through Kong.
  psql(`
    delete from vault.secrets where name in ('notify_url', 'notify_secret');
    select vault.create_secret('http://supabase_kong_swapee:8000/functions/v1/notify', 'notify_url');
    select vault.create_secret('${NOTIFY_SECRET}', 'notify_secret');
  `);
});

test("an upload notifies the member who was waiting, and only once a day", async () => {
  const [alice, bob] = [await signUp("alice"), await signUp("bob")];
  const { data: group } = await alice.client.rpc("create_group", { p_name: "push" });
  await bob.client.rpc("join_group", { p_code: group.invite_code });
  assert.ifError((await alice.client.rpc("register_device", { p_token: `alice-${randomUUID()}` })).error);

  await upload(alice, group.id);
  const claim = await alice.client.rpc("claim_photo", { p_group_id: group.id });
  assert.equal(claim.data.status, "waiting");

  await upload(bob, group.id);

  const notifiedDay = () =>
    psql(`select last_notified_day from public.group_members where group_id = '${group.id}' and user_id = '${alice.id}'`);
  assert.ok(await waitFor(() => notifiedDay() !== ""), "Alice should be marked as notified");
  assert.equal(
    psql(`select last_notified_day = public.swapee_day() from public.group_members where user_id = '${alice.id}'`),
    "t",
  );
  assert.equal(
    psql(`select last_notified_day is null from public.group_members where user_id = '${bob.id}'`),
    "t",
    "the uploader is not notified",
  );
});

test("notify rejects calls without the secret", async () => {
  const res = await fetch(`${env.API_URL}/functions/v1/notify`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.ANON_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ photo_id: randomUUID() }),
  });
  assert.equal(res.status, 403);
});
