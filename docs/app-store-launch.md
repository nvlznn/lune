# Lune 上架 App Store 步驟

這份清單由 Claude 在 2026-10-08 整理。程式碼裡能做的都已經做完（見最後一節），剩下的都是要你登入各個後台才能做的事。照順序做，每完成一項就打勾。

固定資訊：


| 項目         | 值                                                                                |
| ---------- | -------------------------------------------------------------------------------- |
| Bundle ID  | `dev.noky.lune`                                                                  |
| Team ID    | `6KB6SVY565`                                                                     |
| 版本 / Build | `1.0` / `1`（每次上傳都要把 Build 加 1）                                                   |
| 訂閱商品       | `dev.noky.lune.premium.monthly`（US$0.99）、`dev.noky.lune.premium.yearly`（US$7.99） |
| 客服信箱       | `support@noky.dev`                                                               |
| 條款 / 隱私權網址 | `https://lune.noky.dev/terms`、`https://lune.noky.dev/privacy`（寫在 `AppConfig`）    |


---

## 階段 0：上架前要先決定的事

- [ ] **商標**：「Lune」和 Fabulous 的「Lune: Bedtime Sleep Routine」很接近。上架前請找專業人士確認可以用（類別 9、42、45）。
- [ ] **App Store 名稱**：App Store 的名稱是全球唯一，「Lune」單獨很可能已經被用掉。先準備一個帶副標的名稱，例如 `Lune: Nightly Diary`（最多 30 字元）。階段 4 建立 App 時就會知道能不能用。
- [ ] **營運者名稱**：條款和隱私權政策要寫你的名字或公司名稱，以及適用的法律地區。

---

## 階段 1：網站（條款、隱私權、客服頁）

App 裡的連結、訂閱頁和 App Store 都會連到這些網址，所以一定要先上線。

- [x] 網站原始碼在 `website/`（首頁、`/terms`、`/privacy`、`/support`），營運者 Noky、適用台灣法律、資料存放東京都已填好。
- [ ] 部署到 Vercel，網域設為 `lune.noky.dev`：
  ```sh
  cd website && vercel --prod
  ```
  然後在 Vercel 專案的 Domains 加入 `lune.noky.dev`，並在 noky.dev 的 DNS 加上 Vercel 指示的 CNAME。
- [ ] 打開 `/terms`、`/privacy`、`/support` 三個網址，確認都能看到。
- [ ] 確認 `support@noky.dev` 收得到信。
- [ ] 條款和隱私權不是律師寫的，建議給懂法律的人看過。若 Supabase 改選別的地區，要改 `website/privacy.html`。

> 服務條款第 4 節的「零容忍不當內容、可檢舉和封鎖、24 小時內處理」是 Apple 審核 UGC App（Guideline 1.2）時會看的重點，請保留。

---

## 階段 2：正式後端（Supabase）

- [ ] 到 [https://supabase.com](https://supabase.com) 建立正式專案。地區選離使用者近的，例如台灣使用者選 `ap-northeast-1`（東京）。
- [ ] **方案**：免費方案的專案一段時間沒有流量會被暫停，正式上架建議使用 **Pro** 方案。
- [ ] 在 repo 根目錄連結專案，並套用所有資料表和函式：
  ```sh
  supabase link --project-ref <你的 project ref>
  supabase db push
  ```
- [ ] **APNs 推播金鑰**：到 [https://developer.apple.com/account](https://developer.apple.com/account) → Certificates, IDs &amp; Profiles → **Keys** → ＋，勾選 **Apple Push Notifications service (APNs)**，環境選 **Sandbox &amp; Production**，下載 `.p8` 檔。這個檔只能下載一次，請妥善保存。記下 **Key ID**。
- [ ] 設定 secrets 並部署兩個 function。兩個密碼請自己產生一組亂碼，例如用 `openssl rand -hex 32`：
  ```sh
  supabase secrets set CLEANUP_SECRET=<亂碼1> NOTIFY_SECRET=<亂碼2> \
    APNS_KEY_ID=[[ORCA_RICH_MD:728c73cd609c717806e3d0cb691ecff0:inline-html:%3CKey%20ID%3E]] APNS_TEAM_ID=6KB6SVY565 APNS_BUNDLE_ID=dev.noky.lune \
    APNS_ENVIRONMENT=production APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
  supabase functions deploy cleanup
  supabase functions deploy notify
  ```

  TestFlight 和 App Store 的版本都走 production 推播環境，所以這裡填 `production`。
- [ ] 到 Supabase Dashboard → **SQL Editor**，執行下面這段，把 `<ref>` 和兩個亂碼換掉：
  ```sql
  select vault.create_secret('https://<ref>.supabase.co/functions/v1/notify', 'notify_url');
  select vault.create_secret('<亂碼2>', 'notify_secret');
  select vault.create_secret('https://<ref>.supabase.co/functions/v1/cleanup', 'cleanup_url');
  select vault.create_secret('<亂碼1>', 'cleanup_secret');
  select cron.schedule('lune-cleanup-files', '17 * * * *', $$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_url'),
      headers := jsonb_build_object('Authorization', 'Bearer ' ||
        (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_secret'))
    )
  $$);
  ```

  開窗推播和審核帳號換日的排程，已經由 migration 自動建立了。
- [ ] Dashboard → **Authentication → Sign In / Providers**：
  - **Apple**：開啟，在 **Client IDs** 填 `dev.noky.lune`。只有 App 內的原生登入，不需要填 Secret Key。
  - **Email**：保持開啟，審核帳號要用它登入。
- [ ] Dashboard → **Project Settings → API Keys**：複製 **Project URL** 和 **publishable key**（`sb_publishable_...`），填進 `Config/Release.xcconfig`：
  ```
  SUPABASE_URL = https:/$()/<ref>.supabase.co
  SUPABASE_KEY = sb_publishable_...
  ```

  `https:/$()/` 這個寫法是故意的，因為 xcconfig 會把 `//` 當成註解。publishable key 可以放進 App，存取權限由資料庫的 RLS 控管。
- [ ] 同一頁複製 **secret key**（或舊版的 `service_role` key）。這把鑰匙可以繞過所有權限，**絕對不能放進 App 或 git**，只在下一步的腳本裡用一次。

---

## 階段 3：建立審核帳號

Apple 的審核人員沒辦法用別人的 Apple ID 登入，也可能在白天測試，所以要準備一個專用帳號：

- 隨時都能寫日記，不受晚上 20:00 到 04:00 的限制。
- 有三個朋友（Mia、Leo、Ava），每人寄了一封信給它。
- 每次換日，這些信會自動移到新的一天，所以審核哪天測試都看得到。

- [ ] 想一組審核帳號的 email 和密碼，例如 `review@noky.dev`，密碼至少 12 個字元。這個信箱不需要真的收得到信。
- [ ] 執行：
  ```sh
  cd scripts/review-account
  npm install
  SUPABASE_URL=https://[[ORCA_RICH_MD:728c73cd609c717806e3d0cb691ecff0:inline-html:%3Cref%3E]].supabase.co SUPABASE_SERVICE_ROLE_KEY=[[ORCA_RICH_MD:728c73cd609c717806e3d0cb691ecff0:inline-html:%3Csecret%20key%3E]] \
  REVIEW_EMAIL=review@noky.dev REVIEW_PASSWORD=<密碼> npm run setup
  ```

  看到 `Review account ready` 就成功了。
- [ ] 這支腳本可以重複執行。如果審核人員測試了「刪除帳號」或「封鎖朋友」，下次送審前再跑一次就會恢復。
- [ ] **登入方式**：在登入畫面**按住月亮 2 秒**，會跳出 email 登入視窗。這個入口只能登入，不能註冊。

---

## 階段 4：Apple Developer 和 App Store Connect

### 4-1 帳號與協議

- [ ] [https://appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Business**（協議、稅務和銀行）：簽署 **Paid Applications** 協議，填好銀行帳戶和稅務表格。沒有完成這一步，訂閱商品不能上架。

### 4-2 建立 App

- [ ] App Store Connect → **Apps** → ＋ → **New App**：
  - Platform：iOS
  - Name：`Lune: Nightly Diary`（如果被用掉了就換一個）
  - Primary Language：English (U.S.)
  - Bundle ID：`dev.noky.lune`。如果選單裡沒有，先到 Xcode 開啟專案按一次 Archive，或到 Developer 網站的 Identifiers 手動建立，並勾選 **Sign in with Apple** 和 **Push Notifications**。
  - SKU：`lune-ios`
  - User Access：Full Access

### 4-3 訂閱

- [ ] App → **Monetization → Subscriptions** → 建立 Subscription Group，名稱 `Lune Premium`。
- [ ] 在群組裡建立兩個訂閱：
  
  | Reference Name       | Product ID                      | 期間      | 價格      |
  | -------------------- | ------------------------------- | ------- | ------- |
  | Lune Premium Monthly | `dev.noky.lune.premium.monthly` | 1 Month | US$0.99 |
  | Lune Premium Yearly  | `dev.noky.lune.premium.yearly`  | 1 Year  | US$7.99 |
  

- [ ] 每個訂閱都要填：
  - **Localization**（English）：Display Name 填 `Lune Premium`；Description 填 `Read your whole diary, not just the last 30 days.`
  - **Review Information**：上傳一張付費牆截圖（App 裡 Account → Lune Premium），Review Notes 填 `Unlocks reading your own diary pages older than 30 days.`
- [ ] 群組本身也要填 Localization：Display Name 填 `Lune Premium`。
- [ ] 第一次的訂閱必須跟著 App 版本一起送審（在 4-6 選取）。

### 4-4 App 資訊（App Information）

- [ ] Subtitle：`One page a night, for friends`
- [ ] Category：Primary 選 **Lifestyle**，Secondary 選 **Social Networking**
- [ ] Content Rights：選「不包含第三方內容」
- [ ] **Age Rating** 問卷照實回答，重點題目：
  - User-Generated Content：**Yes**（使用者之間會傳送照片和文字）
  - Messaging/Chat：No（沒有聊天，也不能回信）
  - Unrestricted Web Access：No
  - 其他暴力、成人等題目：None
  - 最後的分級以問卷結果為準，有使用者內容的 App 通常不會是最低級別。
- [ ] **License Agreement**：使用 Apple 標準的 EULA 即可。

### 4-5 App 隱私（App Privacy）

- [ ] Privacy Policy URL：`https://lune.noky.dev/privacy`
- [ ] Data Collection 選 **Yes**，勾選下列項目。每一項都設定為：用途 **App Functionality**、**與使用者身分連結**、**不用於追蹤**：
  - Contact Info → **Name**、**Email Address**
  - User Content → **Photos or Videos**、**Other User Content**（日記文字）
  - Identifiers → **User ID**、**Device ID**（推播用的 token）
- [ ] 不要勾選 Purchases，因為訂閱完全由 Apple 處理，你的伺服器不會收到購買資料。
- [ ] 這些內容要和 App 裡的 `Lune/PrivacyInfo.xcprivacy` 一致（已經寫好了）。

### 4-6 版本頁（1.0 Prepare for Submission）

- [ ] **Screenshots**：至少要 **6.9 吋 iPhone**（1320×2868），3 到 10 張。截圖方法：
  1. Xcode 選模擬器 **iPhone 17 Pro Max**，用 Release 設定連正式後端執行，或在 TestFlight 版上截圖。
  2. 先讓狀態列好看一點：`xcrun simctl status_bar booted override --time 9:41 --batteryLevel 100 --cellularBars 4`
  3. 用審核帳號登入，這樣就有現成的信可以截。
  4. 在模擬器按 **⌘S** 存檔。
  5. 建議拍這幾張：Tonight（鎖住的信）、寫日記畫面（選收件人）、Tonight（信解鎖後水平排開）、打開一封信、Diary。
- [ ] **Promotional Text**（可以隨時修改，不用送審）：
  ```
  Write one page tonight — a photo and a few words — and send it to the friends you choose.
  ```
- [ ] **Description**：
  ```
  Lune is a diary you keep at night, and send like letters.
  
  ONE PAGE A NIGHT
  Between 8 PM and 4 AM, write today's page: one photo and a few words about your day.
  
  SEND IT TO WHO YOU CHOOSE
  Send it to all your friends, a group, a few people — or keep it just for yourself. Once a letter is sent, it's sent: no edits, no read receipts, no pressure.
  
  WRITE, THEN READ
  Letters from friends open after you write your own page. They last until the next evening, then they're gone.
  
  YOUR DIARY STAYS
  Every page you write is kept in your diary. Export it any time, free.
  
  No feeds. No likes. No replies. Just a page a night with the people you're close to.
  
  Lune Premium lets you read your whole diary, not just the last 30 days. It renews automatically unless cancelled at least 24 hours before the end of the period; manage it in your Apple Account settings.
  
  Terms of Use: https://lune.noky.dev/terms
  Privacy Policy: https://lune.noky.dev/privacy
  ```

  有訂閱的 App，描述裡一定要有 Terms of Use (EULA) 的連結（Guideline 3.1.2）。
- [ ] **Keywords**（最多 100 字元，用逗號分隔，不要放其他 App 的名字）：
  ```
  diary,journal,daily,friends,night,photo,letters,private,close friends,memories,mood
  ```
- [ ] Support URL：`https://lune.noky.dev/support`
- [ ] Marketing URL：可以不填
- [ ] Version：`1.0`
- [ ] Copyright：`2026 <你的名字或公司>`
- [ ] **In-App Purchases and Subscriptions**：選取兩個訂閱。
- [ ] **App Review Information**：
  - Sign-in required：Yes，填入審核帳號的 email 和密碼
  - Contact：你的姓名、電話、email
  - **Notes**（直接複製，把帳號換成你的）：
    ```
    Lune signs users in with Sign in with Apple. For review, please use the email account below:
    on the sign-in screen, PRESS AND HOLD THE MOON FOR 2 SECONDS to show the email sign-in.
    
    Email: review@noky.dev
    Password: <password>
    
    How Lune works:
    - Each night (8 PM–4 AM local time) you write one page: a photo and a few words.
    - You choose who receives it (all friends by default, a group, chosen friends, or only you).
      Sent pages are final: they can't be edited or deleted, and there are no read receipts.
    - Letters from friends unlock after you write your own page for that day, and disappear
      at 8 PM the next day.
    The review account can write at any hour, and three demo friends (Mia, Leo, Ava) have
    already sent it letters, so you can try everything at any time:
    1. Tonight shows three locked letters. Tap one (or "Write Tonight's Page").
    2. Add a photo and text, choose "Send To" (e.g. Only Me), and save.
    3. The letters open; swipe through them and tap one to read it.
    
    User-generated content safeguards (Guideline 1.2): every letter's ⋯ menu has Report and
    Block. Blocking ends the friendship immediately. Reports reach us and are handled within
    24 hours; the Terms of Service forbid objectionable content.
    
    Account deletion: Tonight → account button (top left) → Delete Account.
    Lune Premium: Account → Lune Premium (unlocks reading your own pages older than 30 days).
    ```

---

## 階段 5：打包上傳

- [ ] 確認 `Config/Release.xcconfig` 已填入正式的 URL 和 key（階段 2）。
- [ ] Xcode 上方的目標裝置選 **Any iOS Device (arm64)**。
- [ ] **Product → Archive**。Archive 預設使用 Release 設定，會連到正式後端，推播環境也是 production。
- [ ] Organizer 會自動打開，選剛剛的 archive → **Distribute App** → **App Store Connect** → **Upload**，簽章用自動管理即可。
- [ ] 上傳後約 10 到 30 分鐘，build 會出現在 App Store Connect 的 TestFlight 頁。加密問題已經在 Info.plist 裡回答（`ITSAppUsesNonExemptEncryption = NO`），不會再問。
- [ ] 如果 Apple 寄信說缺少什麼（例如 ITMS-91053），把信的內容貼給 Claude 處理。

---

## 階段 6：TestFlight 自己測一輪

- [ ] App Store Connect → TestFlight → **Internal Testing** → 把自己加進去，在手機上安裝 TestFlight 版。內部測試不需要審核。
- [ ] 用你自己的 Apple ID 測：
  - [ ] Sign in with Apple 登入，設定名字、username 和頭貼
  - [ ] 允許推播
  - [ ] 晚上 20:00 收到「Tonight's page is open」推播
  - [ ] 寫日記、選收件人、寄出
  - [ ] 用第二支手機或朋友的帳號互加好友、互寄信，對方收到推播
  - [ ] 鎖住的信在寫完後解鎖，點開看完整內容
  - [ ] 只給自己看的日記可以編輯（換照片）、刪除，之後再寄出
  - [ ] 建立群組並用群組寄信
  - [ ] 檢舉和封鎖
  - [ ] 訂閱 Lune Premium：TestFlight 裡的購買是 sandbox，不會真的扣款
  - [ ] Diary 匯出
  - [ ] 刪除帳號
- [ ] 用**審核帳號**登入（按住月亮 2 秒），在白天也走一次階段 4-6 Notes 裡的流程。
- [ ] 測完後重跑一次階段 3 的腳本，把審核帳號恢復原狀。

---

## 階段 7：送審

- [ ] 版本頁的 **Build** 選剛上傳的 build。
- [ ] 確認截圖、描述、隱私、訂閱、審核資訊都填好了。
- [ ] **Add for Review** → **Submit**。
- [ ] 選擇通過後自動上架，或手動上架（建議選手動，方便你控制上線時間）。
- [ ] 審核通常需要 1 到 2 天。被退件的話，把 Resolution Center 的訊息貼給 Claude。

---

## 上架之後：每天要做的事

### 處理檢舉（Guideline 1.2 要求 24 小時內處理）

目前檢舉只會寫進資料庫，不會通知你。請**每天**到 Supabase → SQL Editor 執行：

```sql
select r.created_at, r.reason,
       reporter.username as reporter, reported.username as reported,
       e.id as entry_id, e.text, e.storage_path
from public.reports r
left join public.profiles reporter on reporter.id = r.reporter_id
left join public.profiles reported on reported.id = r.reported_user_id
left join public.entries e on e.id = r.entry_id
order by r.created_at desc
limit 50;
```

- **移除內容**：`delete from public.entries where id = '<entry_id>';`（照片會自動排入刪除）
- **停權**：到 Dashboard → Authentication → Users，找到那個人，選擇 **Ban** 或刪除。

如果之後想要收到即時通知（例如寄 email 或發到 Slack），可以請 Claude 幫你加。

### 每次更新版本

- 把 `CURRENT_PROJECT_VERSION`（Build）加 1；有新功能時也調整 `MARKETING_VERSION`。
- 改了資料庫的話，先執行 `supabase db push`，再上傳 App。
- 送審前重跑一次階段 3 的腳本。

---

## 已知風險（可以之後再處理）

- **Sign in with Apple 的 token 撤銷**：Apple 建議刪除帳號時，同時透過 Sign in with Apple REST API 撤銷授權。目前刪除帳號只會刪除 Supabase 的資料。大多數 App 不做也能通過審核，但如果被要求，需要另外實作。
- **任何人都能用 email 註冊**：Supabase 的 Email provider 為了審核帳號而開著，所以技術上任何人都可以繞過 App，直接用 API 註冊 email 帳號。這些帳號一樣受到所有規則限制，風險很低。
- **時區**：目前每個人用自己的當地日期，跨時區的朋友之間，信的開放時間會錯開。

---

## Claude 已經在程式碼裡完成的部分

- `Lune/PrivacyInfo.xcprivacy`：隱私清單，聲明 UserDefaults 的使用理由（CA92.1），以及收集的資料類型。
- `Config/Info.plist`：`ITSAppUsesNonExemptEncryption = NO`。
- 客服信箱改為 `support@noky.dev`，「Contact Us」會用 email 開啟這個地址。
- **隱藏的 email 登入**：在登入頁按住月亮 2 秒。只能登入，不能註冊；密碼錯誤會顯示「The email or password is incorrect.」。
- **審核帳號的後端支援**：
  - `private.review_accounts`：標記審核帳號，被標記的帳號隨時都能寫日記。
  - `setup_review_account`：只有 service role 能呼叫。
  - 每 10 分鐘執行一次的換日排程。
  - `scripts/review-account`：建立帳號的腳本和示範圖片。
- 服務條款和隱私權政策：`website/terms.html`、`website/privacy.html`。
- 測試全部通過：pgTAP 162 個、Node 整合測試 14 個、Swift 29 個。Release 版可以正常編譯。