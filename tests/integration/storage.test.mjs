// Storage rules and the cleanup function, through the real Supabase API.
// pgTAP covers the SQL; this checks files really upload, are readable or not, and really get deleted.
//
//   cd tests/integration && npm install && npm test

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { admin, befriend, env, fileExists, JPEG, newPath, rpc, signUp, uploadFile, writePage } from "./helpers.mjs";

const CLEANUP_SECRET = process.env.CLEANUP_SECRET ?? "local-cleanup-secret";

async function runCleanup() {
  const res = await fetch(`${env.API_URL}/functions/v1/cleanup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${CLEANUP_SECRET}` },
  });
  assert.equal(res.status, 200, await res.text());
}

let alice, bob, stranger, alicePage;

before(async () => {
  [alice, bob, stranger] = [await signUp("Alice"), await signUp("Bob"), await signUp("Stranger")];
  await befriend(alice, bob);
});

test("a page's photo uploads into your own folder", async () => {
  alicePage = await writePage(alice, { text: "Tonight" });
  assert.ok(await fileExists(alicePage.storage_path));
});

test("no uploads during the day", async () => {
  const sleepy = await signUp("Sleepy", { open: false });
  assert.ok((await uploadFile(sleepy, newPath(sleepy))).error);
});

test("not into someone else's folder, and only JPEGs up to 4 MB", async () => {
  assert.ok((await uploadFile(bob, newPath(alice))).error);
  assert.ok((await uploadFile(bob, newPath(bob), Buffer.from("hello"), "text/plain")).error);
  assert.ok((await uploadFile(bob, newPath(bob), Buffer.alloc(4 * 1024 * 1024 + 1))).error);
});

test("a friend can't read the photo until they write tonight", async () => {
  const locked = await bob.client.storage.from("entries").createSignedUrl(alicePage.storage_path, 60);
  assert.ok(locked.error);

  await writePage(bob);
  const { data, error } = await bob.client.storage.from("entries").createSignedUrl(alicePage.storage_path, 60);
  assert.ifError(error);
  const res = await fetch(data.signedUrl);
  assert.equal(res.status, 200);
  assert.deepEqual(Buffer.from(await res.arrayBuffer()), JPEG);
});

test("strangers can't read it, even with the path", async () => {
  assert.ok((await stranger.client.storage.from("entries").createSignedUrl(alicePage.storage_path, 60)).error);
  assert.ok((await stranger.client.storage.from("entries").download(alicePage.storage_path)).error);
});

test("photos can't be overwritten or deleted", async () => {
  const overwrite = await alice.client.storage
    .from("entries")
    .upload(alicePage.storage_path, JPEG, { contentType: "image/jpeg", upsert: true });
  assert.ok(overwrite.error);
  await alice.client.storage.from("entries").remove([alicePage.storage_path]);
  assert.ok(await fileExists(alicePage.storage_path));
});

test("a replaced avatar is deleted by cleanup; friends can read the current one", async () => {
  const upload = async () => {
    const path = newPath(bob);
    assert.ifError((await bob.client.storage.from("avatars").upload(path, JPEG, { contentType: "image/jpeg" })).error);
    await rpc(bob, "set_avatar", { p_path: path });
    return path;
  };
  const first = await upload();
  const second = await upload();
  const { error } = await alice.client.storage.from("avatars").createSignedUrl(second, 60);
  assert.ifError(error);
  await runCleanup();
  const { data } = await admin.storage.from("avatars").list(bob.id);
  const names = data.map((f) => `${bob.id}/${f.name}`);
  assert.ok(!names.includes(first), "the old avatar is gone");
  assert.ok(names.includes(second), "the current one stays");
});

test("deleting the account deletes its photos after cleanup", async () => {
  await rpc(alice, "delete_account");
  const { data } = await admin.auth.admin.getUserById(alice.id);
  assert.equal(data.user, null);
  await runCleanup();
  assert.equal(await fileExists(alicePage.storage_path), false);
});

test("cleanup needs its secret", async () => {
  const res = await fetch(`${env.API_URL}/functions/v1/cleanup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.ANON_KEY}` },
  });
  assert.equal(res.status, 403);
});
