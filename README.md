# swapee
swap photos with your friends

## 後端（Supabase）

```
supabase/
├── migrations/
│   ├── …_schema.sql    資料表、RLS、成員異動 trigger
│   ├── …_storage.sql   私有 bucket、檔案 policy、7 天過期
│   └── …_rpc.sql       客戶端呼叫的 RPC
├── functions/cleanup/  用 Storage API 刪除排入佇列的檔案
└── tests/              pgTAP：伺服器規則測試清單
tests/integration/      透過真正的 API 測 Storage 與 cleanup
```

所有寫入都走 RPC，客戶端沒有任何資料表的寫入權限。RPC 失敗時 `message` 是錯誤代碼（`already_uploaded_today`、`no_credits`…），完整清單在 `…_rpc.sql` 開頭。

### 幾個和計畫書不同、或計畫書沒寫到的決定

- **照片過期只刪檔、不刪列**：`photos.expired_at` 標記過期，資料列與 `deliveries` 保留，credits（上傳數 − 已收數）才不會因過期而變動。
- **上傳者離開群組或刪除帳號時，收過他照片的人會退回一次資格**：照片與對應的 `deliveries` 一起刪除，所以那次收片不再算數。
- **封鎖不退回資格**：已收到的照片只是隱藏。
- **上傳分兩步**：先把檔案傳到 `photos/{group_id}/{user_id}/{uuid}.jpg`（UUID 小寫），再呼叫 `upload_photo` 登記。Storage policy 只允許今天在該群組還沒傳過的成員上傳，且沒登記的檔案最多 3 個；超過一天沒登記的檔案會被清掉。
- **檔案刪除走佇列**：Storage 檔案不能用 SQL 直接刪除，所以會先寫進 `private.storage_deletions`，再由 `cleanup` Edge Function 刪除。排入佇列的當下，RLS 就已經讀不到這些檔案。
- **邀請碼防猜**：同一個人一小時內猜錯 10 次就暫停。找不到邀請碼時，`join_group` 回傳空陣列，不丟錯。
- `profiles.terms_accepted_at`：首次登入同意條款的時間，透過 `save_profile(p_display_name, p_accept_terms)` 寫入。

### 本機開發與測試

需要 Docker 與 Supabase CLI。

```sh
echo 'CLEANUP_SECRET=local-cleanup-secret' > supabase/.env
supabase start -x realtime,imgproxy,mailpit,studio,logflare,vector,supavisor,postgres-meta
supabase test db                                        # pgTAP，86 項
(cd tests/integration && npm install && npm test)       # Storage／cleanup，11 項
```

### 部署到正式環境（尚未在雲端驗證過）

1. `supabase link`、`supabase db push`
2. `supabase secrets set CLEANUP_SECRET=<隨機字串>`，`supabase functions deploy cleanup`
3. 開啟 `pg_net`，在 SQL editor 設定每小時刪除檔案的排程（過期標記已由 migration 的 pg_cron 每小時執行）：

   ```sql
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
