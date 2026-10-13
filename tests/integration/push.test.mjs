// Push wiring end to end, short of APNs: triggers call the notify Edge Function through pg_net,
// and the function picks targets in SQL. Locally there's no APNs key, so it answers
// {"sent": 0, "skipped": <targets>} right before sending.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { befriend, env, psql, rpc, signUp, writePage, zoneForHour } from "./helpers.mjs";

const NOTIFY_SECRET = process.env.NOTIFY_SECRET ?? "local-notify-secret";

before(() => {
  // The database reaches the function through Kong; the URL and secret live in Vault.
  psql(`
    delete from vault.secrets where name in ('notify_url', 'notify_secret');
    select vault.create_secret('http://supabase_kong_lune:8000/functions/v1/notify', 'notify_url');
    select vault.create_secret('${NOTIFY_SECRET}', 'notify_secret');
  `);
});

const lastResponseId = () => Number(psql("select coalesce(max(id), 0) from net._http_response"));

async function waitFor(check, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

const pendingCalls = () => Number(psql("select count(*) from net.http_request_queue"));

/** Runs `action` and returns the notify function's answer to the call it triggered. */
async function notifyResultAfter(action) {
  // Let calls from earlier steps (e.g. friend requests) finish, so their answers aren't mistaken for this one.
  assert.ok(await waitFor(() => pendingCalls() === 0), "earlier notify calls should finish");
  await new Promise((r) => setTimeout(r, 1500));
  const before = lastResponseId();
  await action();
  assert.ok(await waitFor(() => lastResponseId() > before), "a trigger should call notify");
  return JSON.parse(psql(`select content from net._http_response where id > ${before} order by id limit 1`));
}

test("sending a page notifies nobody: letters arrive at 20:00 the next evening", async () => {
  const [alice, bob] = [await signUp("Alice"), await signUp("Bob")];
  await befriend(alice, bob);
  await rpc(bob, "register_device", { p_token: `bob-${randomUUID()}` });

  // Let calls from earlier steps finish, then send a page and make sure nothing calls notify.
  assert.ok(await waitFor(() => pendingCalls() === 0), "earlier notify calls should finish");
  await new Promise((r) => setTimeout(r, 1500));
  const before = lastResponseId();
  await writePage(alice, { to: [bob] });
  await new Promise((r) => setTimeout(r, 3000));
  assert.equal(pendingCalls(), 0, "no call is queued");
  assert.equal(lastResponseId(), before, "and none was answered");
});

test("a friend request notifies the person asked", async () => {
  const [dave, erin] = [await signUp("Dave"), await signUp("Erin")];
  await rpc(erin, "register_device", { p_token: `erin-${randomUUID()}` });
  assert.deepEqual(await notifyResultAfter(() => rpc(dave, "add_friend", { p_username: erin.username })), { sent: 0, skipped: 1 });
});

test("the opening push goes to people whose diary just opened", async () => {
  const frank = await signUp("Frank");
  await rpc(frank, "register_device", { p_token: `frank-${randomUUID()}` });
  await rpc(frank, "set_time_zone", { p_time_zone: zoneForHour(20) });

  const call = () =>
    fetch(`${env.API_URL}/functions/v1/notify`, {
      method: "POST",
      headers: { Authorization: `Bearer ${NOTIFY_SECRET}`, "Content-Type": "application/json" },
      body: JSON.stringify({ opening: true }),
    }).then((r) => r.json());

  const first = await call();
  assert.ok(first.skipped >= 1, JSON.stringify(first));
  const frankAgain = psql(`select count(*) from private.window_pushes where user_id = '${frank.id}'`);
  assert.equal(frankAgain, "1", "Frank is marked as notified tonight");
});

test("notify rejects calls without the secret", async () => {
  const res = await fetch(`${env.API_URL}/functions/v1/notify`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.ANON_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ opening: true }),
  });
  assert.equal(res.status, 403);
});
