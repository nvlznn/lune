// Sends "a new photo is ready" to members who were waiting when someone uploaded.
// Called by the photos insert trigger (pg_net) with NOTIFY_SECRET. Who to notify is decided in SQL
// (public.push_targets); this only talks to APNs and removes tokens APNs rejects.
//
// Secrets: NOTIFY_SECRET, APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (contents of the .p8 file),
// APNS_BUNDLE_ID (dev.noky.swapee), APNS_ENVIRONMENT ("sandbox" or "production").

import { createClient } from "npm:@supabase/supabase-js@2";

const ALERT = { title: "Swapee", body: "A new photo is ready for you." };

Deno.serve(async (req) => {
  const secret = Deno.env.get("NOTIFY_SECRET");
  if (!secret || req.headers.get("Authorization") !== `Bearer ${secret}`) {
    return new Response("forbidden", { status: 403 });
  }

  const { photo_id: photoId } = await req.json().catch(() => ({}));
  if (typeof photoId !== "string") return new Response("photo_id required", { status: 400 });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: targets, error } = await admin.rpc("push_targets", { p_photo_id: photoId });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!targets?.length) return Response.json({ sent: 0 });
  // Local development has no APNs key; the targets are still marked as notified.
  if (!Deno.env.get("APNS_PRIVATE_KEY")) return Response.json({ sent: 0, skipped: targets.length });

  const jwt = await providerToken();
  const invalid: string[] = [];
  let sent = 0;

  await Promise.all(
    targets.map(async ({ token, group_id }: { token: string; group_id: string }) => {
      const res = await fetch(`${apnsHost()}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": Deno.env.get("APNS_BUNDLE_ID")!,
          "apns-push-type": "alert",
          "apns-priority": "10",
          // A newer notification for the same group replaces an unread one.
          "apns-collapse-id": group_id,
        },
        body: JSON.stringify({ aps: { alert: ALERT, sound: "default" }, group_id }),
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
