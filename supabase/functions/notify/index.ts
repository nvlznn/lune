// Sends Lune's push notifications. The database decides who gets what; this only talks to APNs.
// Called with NOTIFY_SECRET by:
//   * the entry_recipients trigger    {"letter": {"entry_id", "recipient_ids"}} → "Alice sent you tonight's page."
//   * the friend_requests trigger     {"request": {"from_id", "to_id"}}         → "Alice wants to be friends."
//   * pg_cron every 15 minutes        {"opening": true}                         → "Tonight's page is open — Alice and Bob wrote to you."
//
// Secrets: NOTIFY_SECRET, APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (contents of the .p8 file),
// APNS_BUNDLE_ID (dev.noky.lune), APNS_ENVIRONMENT ("sandbox" or "production").

import { createClient } from "npm:@supabase/supabase-js@2";

type Message = { token: string; body: string; kind: "tonight" | "friends" };

Deno.serve(async (req) => {
  const secret = Deno.env.get("NOTIFY_SECRET");
  if (!secret || req.headers.get("Authorization") !== `Bearer ${secret}`) {
    return new Response("forbidden", { status: 403 });
  }

  const payload = await req.json().catch(() => ({}));
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  let messages: Message[];
  try {
    messages = await messagesFor(admin, payload);
  } catch (error) {
    return Response.json({ error: String(error) }, { status: 500 });
  }
  if (messages.length === 0) return Response.json({ sent: 0 });
  // Local development has no APNs key.
  if (!Deno.env.get("APNS_PRIVATE_KEY")) return Response.json({ sent: 0, skipped: messages.length });

  const jwt = await providerToken();
  const invalid: string[] = [];
  let sent = 0;

  await Promise.all(
    messages.map(async ({ token, body, kind }) => {
      const res = await fetch(`${apnsHost()}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": Deno.env.get("APNS_BUNDLE_ID")!,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: JSON.stringify({ aps: { alert: { title: "Lune", body }, sound: "default" }, kind }),
      });
      if (res.ok) {
        sent++;
        return;
      }
      const reason = (await res.json().catch(() => ({}))).reason;
      if (res.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
        invalid.push(token);
      } else {
        console.error("APNs error", res.status, reason);
      }
    }),
  );

  if (invalid.length) await admin.rpc("remove_device_tokens", { p_tokens: invalid });
  return Response.json({ sent, removed: invalid.length });
});

// deno-lint-ignore no-explicit-any
async function messagesFor(admin: any, payload: any): Promise<Message[]> {
  if (payload.letter) {
    const { data, error } = await admin.rpc("push_targets_letter", {
      p_entry_id: payload.letter.entry_id,
      p_recipient_ids: payload.letter.recipient_ids,
    });
    if (error) throw error.message;
    return (data ?? []).map((t: { token: string; writer_name: string }) => ({
      token: t.token,
      body: `${t.writer_name} sent you tonight’s page.`,
      kind: "tonight",
    }));
  }
  if (payload.request) {
    const { data, error } = await admin.rpc("push_targets_request", {
      p_from_id: payload.request.from_id,
      p_to_id: payload.request.to_id,
    });
    if (error) throw error.message;
    return (data ?? []).map((t: { token: string; requester_name: string }) => ({
      token: t.token,
      body: `${t.requester_name} wants to be friends.`,
      kind: "friends",
    }));
  }
  if (payload.opening) {
    const { data, error } = await admin.rpc("push_targets_opening");
    if (error) throw error.message;
    return (data ?? []).map((t: { token: string; writers: string[] }) => ({
      token: t.token,
      body: t.writers.length
        ? `Tonight’s page is open — ${names(t.writers)} wrote to you.`
        : "Tonight’s page is open.",
      kind: "tonight",
    }));
  }
  return [];
}

/** "Alice", "Alice and Bob", "Alice, Bob and Carol", "Alice, Bob and 3 others". */
function names(list: string[]): string {
  if (list.length === 1) return list[0];
  if (list.length === 2) return `${list[0]} and ${list[1]}`;
  if (list.length === 3) return `${list[0]}, ${list[1]} and ${list[2]}`;
  return `${list[0]}, ${list[1]} and ${list.length - 2} others`;
}

function apnsHost() {
  return Deno.env.get("APNS_ENVIRONMENT") === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
}

// APNs rejects tokens refreshed more than once every 20 minutes, so reuse one while this instance is warm.
let cached: { jwt: string; issuedAt: number } | undefined;

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.issuedAt < 50 * 60) return cached.jwt;

  const pem = Deno.env.get("APNS_PRIVATE_KEY")!;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);

  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID") })}.${encode({
    iss: Deno.env.get("APNS_TEAM_ID"),
    iat: now,
  })}`;
  // WebCrypto returns the raw r||s signature that ES256 expects.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));

  cached = { jwt: `${unsigned}.${base64url(new Uint8Array(signature))}`, issuedAt: now };
  return cached.jwt;
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
