// 刪除 Storage 裡該刪的照片檔：過期（7 天）、離開群組、刪除帳號、上傳後沒登記的孤兒檔。
// 資料庫只負責把路徑排進 private.storage_deletions，這裡用 Storage API 真正刪檔。
// 由排程呼叫（見 README），以 CLEANUP_SECRET 驗證呼叫者。

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
    const { data: paths, error } = await admin.rpc("cleanup_pending_paths", { p_limit: BATCH });
    if (error) return Response.json({ error: error.message, removed }, { status: 500 });
    if (!paths || paths.length === 0) break;

    // 已經不存在的檔案不會報錯，所以重跑是安全的。
    const { error: removeError } = await admin.storage.from("photos").remove(paths);
    if (removeError) return Response.json({ error: removeError.message, removed }, { status: 500 });

    const { error: doneError } = await admin.rpc("cleanup_mark_done", { p_paths: paths });
    if (doneError) return Response.json({ error: doneError.message, removed }, { status: 500 });

    removed += paths.length;
  }

  return Response.json({ removed });
});
