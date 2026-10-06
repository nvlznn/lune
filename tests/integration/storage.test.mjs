// 透過真正的 Supabase API 驗證 Storage 規則與 cleanup Edge Function。
// pgTAP 只能測到 SQL；這裡測檔案真的傳得上去、讀得到／讀不到、真的被刪掉。
//
// 用法（本機 supabase start 之後）：
//   cd tests/integration && npm install && npm test

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
const URL = env.API_URL;
const ANON_KEY = env.ANON_KEY;
const SERVICE_KEY = env.SERVICE_ROLE_KEY;
const CLEANUP_SECRET = process.env.CLEANUP_SECRET ?? "local-cleanup-secret";

const admin = createClient(URL, SERVICE_KEY, { auth: { persistSession: false } });

// 最小的合法 JPEG（1×1）。
const JPEG = Buffer.from(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k=",
  "base64",
);

async function signUp(name) {
  const email = `${name}-${randomUUID()}@integration.test`;
  const password = randomUUID();
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(error);
  const client = createClient(URL, ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await client.auth.signInWithPassword({ email, password });
  assert.ifError(signInError);
  const { error: profileError } = await client.rpc("save_profile", { p_display_name: name, p_accept_terms: true });
  assert.ifError(profileError);
  return { id: data.user.id, client };
}

async function rpc(user, fn, args) {
  const { data, error } = await user.client.rpc(fn, args);
  assert.ifError(error);
  return data;
}

function newPath(groupId, user) {
  return `${groupId}/${user.id}/${randomUUID()}.jpg`;
}

async function uploadFile(user, path, body = JPEG, contentType = "image/jpeg") {
  return user.client.storage.from("photos").upload(path, body, { contentType, upsert: false });
}

async function uploadPhoto(user, groupId) {
  const path = newPath(groupId, user);
  const { error } = await uploadFile(user, path);
  assert.ifError(error);
  await rpc(user, "upload_photo", { p_group_id: groupId, p_storage_path: path, p_taken_at: null });
  return path;
}

async function fileExists(path) {
  const [folder, ...rest] = path.split("/");
  const prefix = `${folder}/${rest.slice(0, -1).join("/")}`;
  const { data, error } = await admin.storage.from("photos").list(prefix);
  assert.ifError(error);
  return data.some((f) => f.name === rest.at(-1));
}

async function runCleanup() {
  const res = await fetch(`${URL}/functions/v1/cleanup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${CLEANUP_SECRET}` },
  });
  assert.equal(res.status, 200, await res.text());
}

let alice, bob, carol, groupId, alicePath;

before(async () => {
  [alice, bob, carol] = await Promise.all([signUp("alice"), signUp("bob"), signUp("carol")]);
  const group = await rpc(alice, "create_group", { p_name: "integration" });
  groupId = group.id;
  const joined = await rpc(bob, "join_group", { p_code: group.invite_code });
  assert.equal(joined[0].id, groupId);
});

test("成員可以上傳到自己的資料夾並登記", async () => {
  alicePath = await uploadPhoto(alice, groupId);
  assert.ok(await fileExists(alicePath));
});

test("今天傳過後，再傳檔案會被 Storage 拒絕", async () => {
  const { error } = await uploadFile(alice, newPath(groupId, alice));
  assert.ok(error);
});

test("非成員不能傳到群組", async () => {
  const { error } = await uploadFile(carol, newPath(groupId, carol));
  assert.ok(error);
});

test("不是 JPEG、或超過 4 MB 的檔案被 bucket 拒絕", async () => {
  const notJpeg = await uploadFile(bob, newPath(groupId, bob), Buffer.from("hello"), "text/plain");
  assert.ok(notJpeg.error);
  const tooBig = await uploadFile(bob, newPath(groupId, bob), Buffer.alloc(4 * 1024 * 1024 + 1), "image/jpeg");
  assert.ok(tooBig.error);
});

test("還沒配給：讀不到別人的檔案", async () => {
  const { error } = await bob.client.storage.from("photos").createSignedUrl(alicePath, 60);
  assert.ok(error);
});

test("配給之後：簽名網址讀得到原檔", async () => {
  await uploadPhoto(bob, groupId);
  const result = await rpc(bob, "claim_photo", { p_group_id: groupId });
  assert.equal(result.status, "delivered");
  assert.equal(result.photo.storage_path, alicePath);

  const { data, error } = await bob.client.storage.from("photos").createSignedUrl(alicePath, 60);
  assert.ifError(error);
  const res = await fetch(data.signedUrl);
  assert.equal(res.status, 200);
  assert.deepEqual(Buffer.from(await res.arrayBuffer()), JPEG);
});

test("直接猜檔案路徑：非成員讀不到", async () => {
  const signed = await carol.client.storage.from("photos").createSignedUrl(alicePath, 60);
  assert.ok(signed.error);
  const download = await carol.client.storage.from("photos").download(alicePath);
  assert.ok(download.error);
});

test("檔案不能被覆蓋或刪除", async () => {
  const overwrite = await alice.client.storage.from("photos").upload(alicePath, JPEG, {
    contentType: "image/jpeg",
    upsert: true,
  });
  assert.ok(overwrite.error);
  await alice.client.storage.from("photos").remove([alicePath]);
  assert.ok(await fileExists(alicePath), "remove 沒有權限，檔案應該還在");
});

test("離開群組：照片立刻讀不到，cleanup 後檔案真的被刪", async () => {
  await rpc(alice, "leave_group", { p_group_id: groupId });
  const { error } = await bob.client.storage.from("photos").createSignedUrl(alicePath, 60);
  assert.ok(error);
  await runCleanup();
  assert.equal(await fileExists(alicePath), false);
});

test("刪除帳號：帳號與檔案都消失", async () => {
  const bobPath = (await rpc(bob, "group_state", { p_group_id: groupId })).today_photo.storage_path;
  await rpc(bob, "delete_account", {});
  const { data } = await admin.auth.admin.getUserById(bob.id);
  assert.equal(data.user, null);
  await runCleanup();
  assert.equal(await fileExists(bobPath), false);
});

test("cleanup 需要密鑰", async () => {
  const res = await fetch(`${URL}/functions/v1/cleanup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${ANON_KEY}` },
  });
  assert.equal(res.status, 403);
});
