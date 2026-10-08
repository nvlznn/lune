// Deletes queued files: photos of deleted pages and accounts, replaced avatars, and unused uploads.
// The database queues paths in private.storage_deletions; this removes them through the Storage API.
// Called on a schedule (see README) with CLEANUP_SECRET.

import { createClient } from "npm:@supabase/supabase-js@2";

const BATCH = 100;

Deno.serve(async (req) => {
  const secret = Deno.env.get("CLEANUP_SECRET");
  if (!secret || req.headers.get("Authorization") !== `Bearer ${secret}`) {
    return new Response("forbidden", { status: 403 });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  let removed = 0;
  for (;;) {
    const { data: rows, error } = await admin.rpc("cleanup_pending_paths", { p_limit: BATCH });
    if (error) return Response.json({ error: error.message, removed }, { status: 500 });
    if (!rows || rows.length === 0) break;

    // Page photos and avatars live in different buckets. Missing files don't error, so reruns are safe.
    const byBucket = new Map<string, string[]>();
    for (const { bucket_id, path } of rows as { bucket_id: string; path: string }[]) {
      byBucket.set(bucket_id, [...(byBucket.get(bucket_id) ?? []), path]);
    }
    for (const [bucket, bucketPaths] of byBucket) {
      const { error: removeError } = await admin.storage.from(bucket).remove(bucketPaths);
      if (removeError) return Response.json({ error: removeError.message, removed }, { status: 500 });
    }
    const paths = rows.map((r: { path: string }) => r.path);

    const { error: doneError } = await admin.rpc("cleanup_mark_done", { p_paths: paths });
    if (doneError) return Response.json({ error: doneError.message, removed }, { status: 500 });

    removed += paths.length;
  }

  return Response.json({ removed });
});
