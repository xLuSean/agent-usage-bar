# Safety model

這個 App 以兩條唯讀路徑查詢額度：Claude 執行官方 CLI 的 `/usage` 唯讀指令；Codex 讓官方 App Server 沿用既有登入。App 本身不讀取或保存兩家的憑證；官方 CLI 仍可能在自己的程序內處理登入或續期。本文件記錄它做什麼、不做什麼，以及為什麼。

## 1. 唯讀邊界

App 不做的事，這是硬性清單：

- **不讀取、不寫入鑰匙圈。** 0.3.0 起 App 完全不碰憑證儲存。
- 不修改 `~/.claude`、`~/.codex` 或任一工具的登入與任務狀態。
- 不自行呼叫任何 API。Claude 只執行一個固定的唯讀 CLI 指令；Codex 只允許 initialize handshake 與 `account/rateLimits/read`。
- 不實作 OAuth 登入或 refresh 流程，也不執行任何登入指令，沿用 Claude Code 既有登入狀態。
- 不購買 credits、不啟用自動加值、不修改 spend 設定；不呼叫 `account/rateLimitResetCredit/consume` 或 `account/sendAddCreditsNudgeEmail`。
- 查詢失敗時**不改用**讀取 JSONL、SQLite、transcript 或其他本機檔案的替代方案。
- 設定中的錯誤紀錄只保存時間、供應商與封閉錯誤類型。`UsageError` 內的自由文字、原始回應、JSON key、RPC message、stdout／stderr、執行檔路徑與 provider metadata 都不保存；預設 5 天，可選 3／7 天、隨時清除，且最多 200 筆。
- Claude 與 Codex 子程序不得從 `/`、home、App 安裝位置或使用者專案執行。每個 process instance 只使用 App 在目前使用者本機暫存區建立的空白 `0700` 目錄；建立或驗證失敗時查詢直接失敗，不得 fallback。

兩邊的指令與 arguments 都固定在程式中，沒有任何介面可以提供任意指令、參數或 URL。允許清單就是型別本身（`ClaudeUsageCommand`、`CodexJSONRPCMethod`）。

工作目錄隔離不改 `HOME` 或 provider-specific home。官方 CLI 仍能使用自己管理的登入狀態；App 只讓實際 cwd 與 `PWD` 指向同一個空白本機目錄。這避免 CLI 初始化時把 LaunchServices 常見的 `/` cwd 當成專案，進而碰到根目錄下的網路 volume、自動掛載點或其他受保護資料夾。

### 1.1 Codex App Server 邊界

Codex provider 不讀取 `auth.json`、任務 JSONL、SQLite、cache 或 token。它以 `Process.executableURL` 直接執行使用者指定或驗證過的 `codex` 一般檔案，arguments 固定為 `app-server --listen stdio://`，不經 shell。協定依據是官方 [Codex App Server 文件](https://learn.chatgpt.com/docs/app-server)；本 App 只使用本機 stdio，不開任何遠端 listener。

`CodexJSONRPCMethod` 與 `CodexJSONRPCNotificationMethod` 是封閉 enum，沒有任意 method 輸入介面。官方另有 `account/usage/read`，但那會讀取 token activity summary／daily buckets，與本 App 的即時量表目的及「不保存歷史」原則無關，因此沒有實作。App 只保留解析後的百分比、時間、Credits 狀態、plan 與 App Server user-agent；不記錄完整 response、reset credit ID 或子程序 stderr。stdout callback 先進入單一消費者的有界 FIFO，排隊 bytes 與每一條 JSONL 行（含未完成尾端）各自限制為 4 MB；任何一層超限都捨棄該精確連線。停用、換路徑與結束時只持有並終止自己建立的精確 `Process` instance。

## 2. Claude：執行一個固定的唯讀指令

0.3.0 起，App **不再讀取 OAuth 憑證**。額度數字改由 Claude Code 自己回報：

```bash
claude --safe-mode --no-session-persistence -p "/usage" --output-format json
```

實測（Claude Code 2.1.231）：`is_error=false`、`num_turns=0`、所有 token 計數為 0、`total_cost_usd=0`。這個查詢不跑模型、不消耗對話額度。

- `--safe-mode` 沿用既有登入，同時避開 hooks、plugins、MCP 與專案自訂設定。
- `--no-session-persistence` 讓這次一次性呼叫不留下 session。回應仍帶一個 `session_id`，App **不保存也不顯示**。

### 2.1 arguments 是常數，不是參數

App 現在會**執行**一個程式，而「執行一個程式」的風險範圍完全取決於 arguments 能不能變。它不能：`ClaudeUsageCommand.arguments` 是 `let`，沒有設定介面餵它，也沒有任何回應能影響它。`verify.sh` 有三道靜態護欄 —— 只有 `ClaudeUsageCommand.swift` 可以建構 `Process`、arguments 清單逐字比對、`Claude/` 下不得出現登入／維護指令、shell，或會購買、申請、開啟額外計費的 `usage-credits`／舊名 `extra-usage`。

這個區分是踩出來的：`/usage` 是文件化、唯讀、專門回報這個數字的指令；早期曾為了另一個維護指令**從未承諾的認證副作用**而呼叫它，結果改壞使用者的登入狀態。**為了一個指令的文件用途執行它，和為了它剛好會做的事執行它，不是同一件事。**

### 2.2 App 不再讀憑證，但它執行的指令可能會寫憑證

這句話要照實寫。`/usage` 連得上網路時會更新；一次離線跨窗觀察中，它先回傳舊窗資料，恢復 Wi-Fi 後再次查詢才取得新窗資料。也就是**它需要一張有效的票**。如果票過期，Claude Code 可能在這次呼叫裡順手續期；那是 Claude Code 自己管理的認證行為，不是 App 可以依賴或操控的副作用。指令耗時不能證明有沒有連外；離線與連網樣本的時間互相重疊。

差別在於：續期是 Claude Code 對自己憑證做的事，用的是它自己的流程；App 既不觸發登入、也不寫入任何憑證儲存。但「App 完全不碰憑證」是不準確的說法，正確的說法是**「App 不再讀憑證，但它執行的指令可能會寫憑證」**。

### 2.3 未登入時只複製指令

CLI 回報未登入時，面板提供 `claude` 讓使用者自己去終端機執行。App **不執行登入、不啟動登入流程、不寫入 credential**。理由見 §2.1：換票是副作用不是契約，從外部觸發別人的 refresh 流程沒有失敗收尾的保證。

找不到執行檔或版本過舊時**不提供指令** —— 那兩種情況要的是安裝或更新，給一個按了也沒用的按鈕只會浪費使用者的時間。

## 3. 資料新鮮度：這條路的主要弱點

`/usage` 連不上伺服器時會**安靜地退回 Claude Code 的本機快取**（實測：斷網仍回傳數字），而輸出裡**沒有「這筆數字是幾點拿到的」**。所以一筆過舊的讀數，光看內容分辨不出來。

### 3.1 用 reset 時間當守門

重置時間是跟著那份快取一起存下來的，所以來自舊時間窗的讀數會帶著舊的重置時間。

- 重置時間還沒到 ⇒ 這筆快取寫在當前窗內 ⇒ **最舊不超過一個窗**（session 窗是 5 小時）。
- 重置時間已經過了 ⇒ 這筆讀數描述的是一個已經結束的窗 ⇒ **判定不可用**，顯示「未知」而不是那個百分比。

守門有 60 秒寬限，吸收時鐘誤差與「真實邊界 00:59:59 vs 文字寫 1am」這一秒的差距，否則每次窗滾動都會閃爍。

session 與 weekly 兩個必要時間窗都各自檢查 reset。任一窗已超過 reset 與 60 秒寬限，整份讀數就判定不可用；session 尚未跨界不再能替已過期的 weekly 數字背書。

CLI 文字指定的 IANA timezone 必須能辨識。未知 timezone 會讓 reset 解析失敗並 fail closed，不再退回呼叫端或本機時區猜測。

**沒有 reset 時間的 session 讀數只在明確為 0% 時接受。** CLI 已實際印出 `Current session: 0% used`；那個 0% 是明確數值，不是 App 補上的預設值。若沒有 reset 卻是任何非零百分比，解析器會 fail closed，因為不能在失去 session 新鮮度邊界時仍採信用量。

代價是這種讀數**無法判斷新舊**。殘餘風險很窄：必須同時斷網、快取剛好停在空檔那一筆、而且新的窗已經開始，才會顯示過時的 0%。相對地，若改成一律拒絕，使用者每天收工到隔天開工之間都會看到「不可用」——一個天天出現的假警報會讓真正的故障失去意義。

### 3.2 守門的關鍵假設：一次離線跨窗觀察（2026-08-28）

守門要成立，必須排除兩種不同的失效方式。它們很容易被混為一談，但機制完全無關：

- **(A) 重置時間自己往前跑。** 若那個值是相對的、每次讀取重算，放著不動的舊快取也會長出新的重置時間。
- **(B) 窗滾動時被改寫。** Claude Code 寫入新的重置時間，卻沿用舊的百分比。

**(A) 已排除。** 一次性檢視 Claude Code 記錄的 rate-limit 資料：

```text
rateLimitType: 'five_hour'
resetsAt:      <absolute Unix timestamp>
```

存的是絕對 Unix 時間戳，不是可重算的相對值。寫死的整數不會自己前進，所以**單純放著不動的舊快取，必然帶著它當初那個舊的重置時間**。該整數也與同期 `/usage` 文字輸出的重置時刻吻合。

**(B) 在這一次觀察中沒有發生。** 測試機當時只有 Wi-Fi；關閉 Wi-Fi 後跨過 session 重設，再等過 60 秒寬限，`/usage` 仍回傳上一個窗的非零百分比與已經過去的 reset。兩個舊欄位一起保留，沒有出現「舊百分比配新 reset」。App 因此會把整份讀數判定為過期，而不是顯示那個舊百分比。

恢復 Wi-Fi 後再次查詢，指令改為 `Current session: 0% used`，沒有 reset 子句。這同時確認了新窗尚未提供 reset 時的真實輸出形狀。

腳本的網路探針不能當證據：它用仍留在路由表裡的預設路線判成 `net=online`，但測試機只有 Wi-Fi，且 Wi-Fi 當時確實關閉。路由項目存在不等於仍可連線；之後不得再用這個探針或 `duration_ms` 判斷離線。

**一個由 source 保證的下限。** weekly 那行的重置時間在解析器裡是**必要**的，session 那行才是選用（[ClaudeUsageTextDecoder.swift:95](../macos/AgentUsageBar/Sources/UsageMeterCore/Claude/ClaudeUsageTextDecoder.swift#L95)）。因此每一份被接受的讀數，至少帶著一個 `resetsAt` 進入守門迴圈 —— **守門不可能因為「這份讀數沒有重置時間」而整個被繞過。**

但要講清楚它保證到哪裡為止：weekly 的重置一週才動一次，所以一份「新的 session 重置搭配舊的百分比」的讀數，仍可能從一個還有好幾天才到期的 weekly 重置底下通過。這條擋掉的是「守門完全不作用」，不是 (B)。

**證據等級：**

| 主張 | 強度 |
|---|---|
| weekly 必帶重置時間，守門必定被執行 | 由 source 證明 |
| 重置時間是絕對 Unix 時間戳 | 由一次性診斷直接觀察 |
| (A) 不成立 | 由上一條推得，強 |
| (B) 在這次觀察中沒有發生 | 一次離線跨窗直接觀察；單一樣本、單一 CLI 版本，不是永久契約 |

> [!IMPORTANT]
> 這次檢視是**一次性診斷**，用來決定守門的設計是否站得住。App 本身**不得**讀取 Claude Code 的內部檔案作為資料來源或備援 —— §1 的唯讀邊界不因此放寬。

### 3.3 守門抓不到什麼

**窗內的落後抓不到。** 最壞情況是一筆最多 5 小時舊、但看起來正常的 session 數字。這是改走 CLI `/usage` 之後保留的已知限制，後果是「數字偏舊」。§3.2 只證明目前測試的 CLI 版本在那一次離線跨窗時沒有發生 (B)；日後版本若改變快取寫法，仍須重新驗證。
## 4. 額度消耗

**兩條查詢都不消耗使用者的對話額度。** Claude 是 CLI 的 `/usage` 指令（實測 `num_turns=0`、所有 token 計數為 0）；Codex 是 App Server 的帳號限額讀取。這條直接排除了以推論請求測量推論額度的做法 —— 曾評估過對 `POST /v1/messages` 送極小請求再讀 header，該路徑可用但本身就是一次推論，因此從未實作，並隨舊路徑一起退場。

## 5. 限流安全

限流仍以**帳號**計算 —— 帳號沒變，`/usage` 連網時打的多半也是同一類端點。但發請求的人從本 App 變成了 Claude Code：重試行為、指紋與退避都在 CLI 手上，App 預設每 10 分鐘請它回答一次。

**這帶來一個觀測能力的退步，必須寫清楚：** 被限流時 CLI 多半會像離線一樣安靜地退回本機快取，所以 App 拿到的是一個看起來正常的舊數字，而不是明確的 `throttled` 狀態與恢復時間。§3 的 reset 守門是這種情況下唯一的防線，而它只擋得住舊超過一個窗的資料。

App 自己的節流參數仍然保留，理由從「避免被罰」變成「不要替 CLI 增加沒有意義的認證請求」：

| 參數 | 值 | 理由 |
|---|---|---|
| 預設輪詢間隔 | 600 s | 每天約 144 次。0.3.1 從 1800 s 降下來 —— 舊值是為了避開由 App 自己控制重試才會踩到的懲罰迴圈。不再往下降的理由是**沒有回饋**：被限流時多半只會退回快取，不會報錯 |
| 退避起點 | 60 s | |
| **退避上限** | **1800 s** | 沿用舊值；現在只是本 App 對重複啟動 CLI 的保守上限，不再是「必須大於舊端點懲罰窗」的 shipping invariant |

現行 live provider 不會產生 `.rateLimited(retryAfter:)`，所以舊 HTTP 路徑的 `Retry-After` padding／cap 與懲罰窗 invariant 已從程式移除。每個 provider 的一般指數失敗退避與 cap 仍保留；睡眠、螢幕關閉與鎖定時暫停輪詢 —— 沒人看的時候啟動子程序沒有意義。

### 5.1 排程看不到的那些路徑

輪詢間隔只管得到計時器。**重開 App、喚醒、解鎖、連按重新整理**都繞過它，而 App 原本什麼都不留，所以每次啟動都會立刻發一次請求 —— 關掉再開十次就是十次請求。

`FetchPacing` 補上這一層：比輪詢間隔新的讀數繼續用（見 [ARCHITECTURE.md](ARCHITECTURE.md) §8），且**任何來源都不得在 20 秒內連送兩次**。手動重新整理只受後者限制，理由見 [ARCHITECTURE.md](ARCHITECTURE.md) §9。

供應商建議值分開保存，但**目前兩邊都是 10 分鐘**：Claude 完全靠輪詢，Codex 同時接收 App Server 的 `account/rateLimits/updated`，所以 Codex 的 10 分鐘只是保險查詢。OpenAI 沒有公布 `account/rateLimits/read` 的最低輪詢間隔或固定懲罰窗；App 不把「未文件化」誤寫成「保證不限流」。

## 6. 客戶端識別：已不再適用

舊路徑必須模擬 Claude Code 的客戶端識別，代價是**這個 App 在連線上無法與官方 CLI 區分**。那是一個已退役的產品層級取捨。

**0.3.0 之後這個問題消失了** —— 現在對外發請求的就是官方 CLI 本身，App 沒有自己的連線，也沒有身分可以冒充。`ClientIdentity` 型別、三個選項與 D1 護欄都已移除；`verify.sh` 改成反向護欄，禁止 `claude-cli/` 這個字串回到程式碼裡。

舊的直接 Keychain／OAuth 路徑已從公開版本完整移除，不保留自動 fallback。

## 7. 商標邊界

所有圖示為原創設計，不使用 Anthropic 或 OpenAI 的官方標誌。這不只是保守做法，而是設計上的必然：選單列慣例為單色自適應圖示，把彩色 logo 轉單色即構成「更改 logo」，兩家品牌規範皆禁止；而核心設計是在圖形內部繪製液位，那是第二次改圖。

App 自身識別（Dock 圖示、About、DMG）一律不使用他人標誌。About 頁明載本 App 與兩家公司均無隸屬關係。

## 8. 已知的未驗證項目

誠實記錄，不因為看起來完成而標記為完成：

- **`/usage` 文字格式的長期穩定性未知。** 百分比包在為人閱讀的英文散文裡，沒有欄位 schema。解析器逐字錨定兩行、對不上就 fail closed，所以格式改變會變成「顯示未知」而不是「顯示錯的數字」—— 但功能確實會失效。這是產品風險，不是實作缺陷。
- **輸出是否會依系統語言在地化，部分排除。** 實測 2026-08-26：以 `LANG=zh_TW.UTF-8 LC_ALL=zh_TW.UTF-8` 執行，回傳的仍是同一份英文，**`/usage` 目前根本不看 locale 環境變數**。子程序仍固定 `LANG`／`LC_ALL` 作為保險，但真正保護讀數的是 fail-closed 的解析器。尚未排除的是：若日後改以設定檔或帳號語言偏好在地化，仍會讓解析失敗（結果是顯示「未知」，不是解錯數字）。
- **跨窗行為只直接觀察過一次。** 2026-08-28 在單一 Claude Code 版本上，離線跨過 reset 與 60 秒寬限後，舊百分比與舊 reset 一起保留，守門正確拒絕；恢復 Wi-Fi 後才取得 `0%`、無 reset 的新窗輸出。這提高了對現行守門的信心，但不是未來版本的永久保證。
- **`/usage` 是否反映不經過 Claude Code 的用量仍未證實。** 指令耗時已確認不能回答這件事；決定性的測試是用 Claude Desktop 或 claude.ai 消耗額度後再查一次。
- **未經 Apple 公證。** 建置機器上的 `spctl` 已回報 `rejected`；從瀏覽器下載、帶 quarantine 標記的完整 Gatekeeper 流程仍未在第三方機器上實測。README 記錄預期放行步驟，但在乾淨 Mac 驗收前不把特定提示文字或步驟宣稱為保證。
- **支援 `/usage` 的最低 Claude Code 版本未確立。** 沒有硬編最低版本；能力以實際執行結果判定，指令被拒時提示更新。
- ~~Codex live 尚未執行。~~ **已於 2026-08-20 由實機 App 驗證**：畫面顯示資料狀態「最新」、來源「Codex app-server」與真實使用比例。這證明唯讀 App Server 路徑可用；App 沒有保存原始 response，測試套件仍只使用合成 payload。

### 8.1 已確認的實作缺口與修正狀態

這些不是外部服務的不確定性，而是 2026-08-25 起的 review 已由當時 source 證實、再由現行測試封住的問題：

- ~~Codex sparse notification 可能把完整 snapshot 替換成缺欄位的 snapshot。~~ **已修正**：只合併實際提供的欄位，保留已知資料、狀態與完整查詢排程。
- ~~Codex request timeout 不會讓可能已卡住的 App Server connection 失效。~~ **已修正**：捨棄 exact owned connection，下一次查詢以新程序重新 initialize；停止先嘗試 cooperative terminate，短暫 grace 後只對同一個 exact owned root child 強制結束。
- ~~provider 路徑／fixture／enabled 切換與 in-flight fetch 之間缺少 generation，舊結果可能覆蓋新意圖。~~ **已修正**：每個 provider 各自推進 configuration generation；舊結果不更新畫面、儲存、退避或排程。Codex 路徑切換另以 generation token 約束非同步 stop，只刷新仍屬於目前設定的 provider。
- ~~Claude subprocess timeout 只有 cooperative terminate，沒有 hard escalation。~~ **已修正**：取消會跨越 adopt 競態保留；timeout 後先 `SIGTERM`，1 秒後僅對 App 自己的精確 root child 強制結束，並關閉自己持有的 pipe read ends。App 不掃描程序或殺 process group。
- ~~Codex 範圍外百分比會被 clamp 成 0／100，而不是視為 schema failure。~~ **已修正**：`usedPercent` 在 provider 邊界驗證整數與 `0...100`；時間欄位及 JSON-RPC envelope 也不截斷小數，共用 schema 文案保持 provider-neutral。
- ~~跨啟動保存的 JSON 只做 Codable 解碼，可能繞過 live provider 的百分比、身分與時間界線。~~ **已修正**：`UsedPercent` 解碼本身拒絕非有限或範圍外數字；`UsageSnapshotStore` 再確認 provider、來源、fixture、非空時間窗、非未來 `fetchedAt`，以及所有有 reset 的窗仍未過期。現行 Claude CLI 快照另須符合與 live decoder 相同的結構：session 缺 reset 只接受 `0%`，weekly 必須有 reset；Codex 合法的 optional reset 不受影響。拒絕的快取不會顯示，也不會阻止下一次正常查詢。
- ~~AppKit 可能在 Codex hard-stop 或 Claude fetch 取消完成前結束程序。~~ **已修正**：結束 App 先凍結所有 presenter、取消並等待其 fetch，再等待 exact owned Codex root 確實退出，最後才回覆 AppKit。測試使用會忽略 `SIGTERM` 的中性 fixture，確認 `stop()` 不會提早返回。
- ~~Codex stdout 每個 callback 都先建立一個 Task，JSONL 的 4 MB 上限管不到前面排隊的 Task 與 Data。~~ **已修正**：每個 connection generation 只有一個依序消費者，callback 片段在前置 FIFO 合併並另受 4 MB 上限約束；十萬個一位元組 callback 只會排出一個 consumer，overflow 在增加新工作前 fail closed。
- ~~Claude process fixture cleanup 從暫存檔重讀 bare PID 後送 `SIGKILL`，PID 重用時可能終止無關程序。~~ **已修正**：測試不再保存、解析或 signal PID；具有 UUID 路徑的 stop marker 只讓知道該 capability 的 fixture descendant 自行退出，另有靜態護欄禁止舊模式返回。正式 App 的 exact-`Process` ownership 不受影響。

上述修正、Codex 外部錯誤文字清理與打包交易化均已完成。現行回歸證據集中在 [VERIFICATION.md](VERIFICATION.md)。

### 8.2 Credential 調查規則

開發與除錯不得用會輸出密碼本體的 Keychain 參數，也不得把 token、完整 credential blob 或 raw provider response 貼進終端輸出、issue、測試 fixture、對話或診斷。若只需確認項目是否存在或清點數量，只讀 metadata；不需要、也不應讀取秘密內容。任何懷疑已曝光的 credential 都應立即以供應商支援的方式撤銷或更換，不可只等待自然過期。
