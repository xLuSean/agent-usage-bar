# Codex 的額度資料來源

App 如何取得 Codex 的方案額度：唯讀方法、欄位、更新方式與失敗邊界。Claude 那一側見 [CLAUDE_USAGE.md](CLAUDE_USAGE.md)；兩者共用的安全、狀態與視覺語言見 [SAFETY.md](SAFETY.md)、[ARCHITECTURE.md](ARCHITECTURE.md) 與 [UI_SPEC.md](UI_SPEC.md)。

**App 自己不發任何 HTTP 請求，也不讀取 Codex 的 token 或本機資料庫。** 數字來自官方 Codex CLI 的 [App Server](https://learn.chatgpt.com/docs/app-server)，透過本機 stdio 的唯讀 JSON-RPC 取得。

## 1. 一個固定的本機 App Server

```text
codex app-server --listen stdio://
```

arguments 是常數，不經 shell，也沒有設定或上游回應能加入其他參數。App Server 是長駐子程序：第一次需要資料時啟動，完成 `initialize` → `initialized` handshake，之後讓同一條連線負責查詢與更新通知。

官方協定省略 wire 上的 `"jsonrpc":"2.0"` 欄位；stdio 每行一筆 JSON（JSONL）。本 App 不開 WebSocket、Unix socket、TCP listener 或其他遠端入口，App Server 只和啟動它的 App 經 stdin／stdout 溝通。

## 2. 唯讀允許清單

App 能建構的 outbound method 只有：

| 類型 | method | 用途 |
|---|---|---|
| request | `initialize` | 宣告 client 名稱與版本，取得 App Server user-agent |
| notification | `initialized` | 完成 handshake |
| request | `account/rateLimits/read` | 讀取目前的方案額度 |

額度查詢的 wire message 是：

```json
{"method":"account/rateLimits/read","id":2}
```

`CodexJSONRPCMethod` 與 `CodexJSONRPCNotificationMethod` 是封閉 enum，沒有任意 method 或 params 入口。官方 App Server 還有登入、token activity、寄信與消耗 reset credit 等其他方法，但本 App 不實作也不呼叫它們；尤其不使用 `account/usage/read` 建立活動歷史，也不呼叫 `account/rateLimitResetCredit/consume` 或 `account/sendAddCreditsNudgeEmail` 改變帳號狀態。

## 3. 哪些欄位進入 App

App 優先讀 `rateLimitsByLimitId.codex`；沒有時才使用官方保留的向後相容 `rateLimits`。其他 limit ID 目前不顯示，也不會讓一般 `codex` bucket 失敗。

| 欄位 | App 的處理 |
|---|---|
| `primary` | 量表代表窗，映射為 session window |
| `secondary` | 顯示於詳情，`codex` bucket 映射為 weekly window |
| `usedPercent` | 必須是 `0...100` 的整數；決定數字與共用量表顏色 |
| `windowDurationMins` | 可缺或為 `null`；有值時必須是整數 |
| `resetsAt` | 可缺或為 `null`；有值時必須是 Unix seconds 整數 |
| `credits`、`planType` | 有值時顯示於詳情 |
| `rateLimitReachedType`、`spendControlReached` | 保留上游限制狀態，但不改寫共用顏色刻度 |
| initialize 的 `userAgent` | 顯示資料來源版本，供診斷使用 |

`rateLimitResetCredits` 可能出現在官方回應中，但 App 不解析或保存 opaque credit ID，也沒有 consume 方法。

JSON-RPC request ID、error code 與 provider 的整數欄位共用同一套精確檢查。小數不會被截斷成看似合法的整數；範圍外、非整數或錯誤型別會回 `schemaChanged`，不讓共用 `UsedPercent` clamp 把壞資料畫成可信的 0%／100%。

## 4. 推播不是完整查詢

`account/rateLimits/updated` 是 App Server 主動送來的 notification，沒有 request ID。它可能只包含 primary window，不能當成完整 `account/rateLimits/read`。

合併規則是：

- 只更新 notification 實際提供且 window identity 相符的欄位。
- 缺少或 `null` 的 optional metadata 不會清掉已知的 weekly、Credits、plan 或來源版本。
- 保留原本的 display-state case、完整查詢的 `fetchedAt`、失敗 backoff 與 10 分鐘保險查詢。
- 沒有可信 base snapshot，或 limit identity 不相容時，忽略局部 notification。

因此推播能讓畫面提早反映變化，但不能把自己冒充成一次完整、成功的新查詢。下一次完整 read 仍負責校正整份 snapshot。

## 5. JSONL 與錯誤容錯

回應以 request ID 配對；notification 不會冒充 response。JSONL buffer 支援資料被拆成多次 read、一次黏住多行與 CRLF：

- 單一非 JSON 或不相關訊息會被隔離，不破壞後續合法訊息。
- stdout callback 不會各自建立一個等待中的 Task。每條連線只有一個依序消費者；尚未交給 actor 的片段先按原順序合併，總量超過 4 MB 就停止讀取並捨棄該精確連線。
- 進入 parser 後，每一條 JSONL 行與最後尚未換行的尾端另有獨立 4 MB 上限。parser 先切出完整行再檢查尾端，不會因一次 read 暫時包含多條合法訊息就誤拒。前後兩道上限分別約束「排隊中」與「單一行」的資料，長期合法通知不會按連線生命週期累加。
- `error.message` 是不可信的 provider 文字，只用於分類「未登入／版本不支援／一般失敗」。UI 只顯示 App 自己寫的固定訊息與數字 error code，不顯示、保存或記錄原始 message。

## 6. 更新頻率與資料新鮮度

通知是主要的即時更新來源；預設每 10 分鐘另做一次完整 `account/rateLimits/read`，用來校正漏掉、延遲或內容不完整的 notification。任何來源仍受 `FetchPacing` 的 20 秒防連點底線約束。

失敗時從 60 秒開始指數退避，最高 15 分鐘。OpenAI 官方文件描述 read 與 updated notification，但目前沒有為這個唯讀 method 指定最低輪詢間隔、每分鐘上限或固定懲罰窗。10 分鐘 safety poll 與 15 分鐘退避上限是本 App 的保守策略，不是官方限制。

完整 read 成功時才更新 `fetchedAt`。notification 不重設這個時間，也不延後 safety poll；查詢失敗時，共用狀態會把最後一筆資料明示為 stale，而不是讓局部推播把它升級成「最新」。

## 7. Process recovery

`CodexAppServerClient.shared` 是 App 內唯一的 App Server owner。initialize 最長等 10 秒，rate-limit read 最長等 15 秒。意外退出或 request timeout 時，client 會讓 exact owned connection 失效；逾時的 request 保留精確 `codexRequestTimedOut`，其他 pending request 以連線不可用結束。下一次 fetch 會啟動新程序並重新 handshake。

停用 Codex、變更 CLI 路徑、結束 App 或捨棄故障連線時，只處理這個 client 自己建立的精確 `Process`：

1. 關閉本 App 持有的 stdin／stdout handle。
2. 對該 process 送 `SIGTERM`。
3. 等待 1 秒；若同一個精確 root PID 仍在執行，才送 `SIGKILL`。
4. 在 Foundation 觀察到 exit 前持續強引用該 `Process`，避免重試時遺失 ownership；App 結束流程會等待這個 exit 觀察完成後才回覆 AppKit。

App 不掃描其他程序、不殺 process group，也不會碰 Codex Desktop 或使用者自行啟動的 Codex CLI。中性 fixture 會真的忽略 `SIGTERM`，測試確認 hard stop 後沒有 orphan process。

## 8. 執行檔與登入邊界

GUI App 的 `PATH` 通常比終端機短。設定指定路徑時以該路徑為準；留空時依序檢查 `CODEX_EXECUTABLE` 開發環境值、常見安裝位置與目前 `PATH`。symlink 會先解析，接著只驗證目標存在、不是資料夾而且可執行。

這不等於驗證該 binary 由 OpenAI 發布或簽署。加入固定 Team ID／簽章檢查前，必須先證實 npm、原生 installer 與其他合法安裝方式具有一致且可依賴的簽章；目前的使用者責任是只選擇自己信任的 Codex 安裝。

App Server 回報未登入時，介面只請使用者自行在 Codex CLI 或 Codex App 完成登入，再按重新整理。本 App 不啟動登入、登出、換票或帳務流程。

## 9. 已驗證 vs 未驗證

**已驗證**

- 目前官方 App Server 文件確認 stdio JSONL、initialize handshake、`account/rateLimits/read`／`updated`、multi-bucket 與各 rate-limit 欄位。
- 本機 `codex-cli 0.148.0`／`0.149.0` 產生的版本化 schema，確認 `usedPercent` 為必填整數，`windowDurationMins`／`resetsAt` 為 nullable 整數。暫存 schema 未寫入 repo。
- 自動測試涵蓋 multi-bucket、相容 fallback、sparse notification 合併、Credits、未知欄位、壞型別、數值範圍、request routing、十萬個 tiny stdout callbacks 的單一有界消費、兩層 4 MB 上限、timeout recovery、raw error 清理與抗拒 `SIGTERM` 的 child。
- 2026-08-20 的實機 App 成功顯示資料狀態「最新」、來源「Codex app-server」與真實使用比例。原始 response 未被保存。

**未驗證**

- 官方沒有提供本 App 可直接套用的最低安全輪詢間隔或固定限流懲罰窗。
- 自動化測試不接觸真實 Codex 帳號，也不保存真實 response；實機成功證據不是每次 build 都重跑的測試。
- 其他 limit ID 的產品語意尚未決定，因此目前只顯示一般 `codex` bucket。
- 不同合法安裝方式的簽章狀態尚未盤點，因此 executable locator 不做 vendor identity 驗證。
