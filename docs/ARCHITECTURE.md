# Architecture

## 1. 目標與邊界

Agent Usage Bar 在選單列呈現 agent 訂閱額度的消耗程度。它是**唯讀**的：不修改任何帳號狀態、不寫入 Claude Code 的資料、不呼叫任何寫入型 API。

共同層只定義**使用者看得到的那一層** —— 量表的視覺語言與狀態語意。資料如何取得、憑證如何處理、輪詢與退避參數、錯誤型別，各 provider 各自決定，而且**部分不應強行統一**（見 §5）。

Claude 與 Codex provider 都已實作，而且**兩邊現在都透過官方 CLI 取得資料**。Claude 每次查詢啟動一個一次性子程序執行 `/usage`；Codex 維持一個長駐 App Server 並以 stdio JSONL 查詢。兩者只在 `UsageProvider` 回傳的 snapshot 與共用顯示語意交會，傳輸與生命週期互不綁定。

## 2. 元件分層

```text
NSStatusItem × N            ← 選單列，每個 provider 一個（或合併為一個）
  └─ NSPopover
       └─ UsagePopoverView (SwiftUI)
NSWindow
  └─ SettingsView (SwiftUI)
          │ 讀狀態、送意圖
          ▼
AppModel (@MainActor, @Observable)
  └─ ProviderPresenter × N (@MainActor, @Observable)
       ├─ 自己的輪詢計時器
       ├─ 自己的 RetryBackoff
       └─ 自己的 UsageDisplayState
          │
          ▼
UsageProvider protocol           fetch() async throws -> UsageSnapshot
  ├─ ClaudeUsageProvider
  │    ├─ ClaudeExecutableLocator    GUI PATH、指定路徑與可執行驗證
  │    ├─ ClaudeUsageCommand         固定 arguments；唯一可建構 Process 的地方
  │    ├─ ClaudeUsageTextDecoder     外層 JSON ＋ 兩行錨定文字；fail closed
  │    └─ ClaudeSignInRecovery       只提供可複製的登入指令，不執行登入
  ├─ CodexUsageProvider
  │    ├─ CodexExecutableLocator      GUI PATH、指定路徑與可執行驗證
  │    ├─ CodexAppServerClient actor  單一長駐 Process、request router、推播
  │    ├─ CodexOutputIngress           callback 前置的有界 FIFO、單一消費者
  │    ├─ CodexJSONLBuffer            拆包／黏包與壞行隔離
  │    └─ CodexRateLimitDecoder       一般 codex bucket、Credits、schema 容錯

Debug-only diagnostics
  └─ DemoScenario                    合成狀態；只供 render／self-test，不進 Release

支援設施（不屬於任何單一 provider）
  ├─ AppInstanceCoordinator            核心鎖選出唯一執行個體；新副本讓位
  ├─ ProviderProcessWorkingDirectory  每次啟動建立空白、本機、私人 cwd
  ├─ FetchPacing                     決定一次 refresh 到底送不送請求（§9）
  ├─ RetryBackoff                    每個 Presenter 各自持有的失敗退避
  └─ UsageSnapshotStore              跨啟動保存最近一次讀數（§8）
```

`UsageMeterCore` 不含 AppKit 與 SwiftUI。兩個 provider 都只啟動固定參數的官方 CLI 子程序，App 自己不發任何 HTTP 請求。核心被非主執行緒的 async 程式呼叫，因此**不得假設 main actor 隔離** —— `verify.sh` 有一道護欄檢查這件事，理由見 §7。

Release target 只連結 `UsageMeterCore`，Presenter 永遠使用 live provider，設定頁沒有 fixture／demo 切換。合成 `DemoScenario` 以 `#if DEBUG` 留在 App 診斷 source，供 render／self-test 使用；Release binary guard 會檢查 fixture 型別與文案沒有重新進入成品。

## 3. 目錄結構

```text
macos/AgentUsageBar/          Swift Package 根目錄
├── Package.swift
├── Sources/
│   ├── AgentUsageBar/        App 層；Debug-only 診斷情境也在此
│   └── UsageMeterCore/       純邏輯，可獨立測試
├── Tests/UsageMeterCoreTests/
└── App/AgentUsageBar/
    ├── AgentUsageBar.xcodeproj
    └── AgentUsageBar/        Info.plist 與 Resources/AppIcon.icns
```

Xcode target 以**同步資料夾**（`PBXFileSystemSynchronizedRootGroup`）引用 `Sources/AgentUsageBar`，新增檔案自動屬於 target。這避開了「檔案沒加進 target、`swift build` 過了但 App 找不到符號」這類問題。

代價是 `swift build` 不再編譯 App 層 —— 只有 `xcodebuild` 會。這不是理論風險：一個型別錯誤與一次執行期當機都是 `swift build` 通過、`xcodebuild` 才抓到的。因此 `verify.sh` 必須跑 `xcodebuild`。

## 4. 狀態模型

```swift
enum UsageDisplayState {
    case starting
    case refreshing(previous: UsageSnapshot?)
    case current(UsageSnapshot)
    case stale(UsageSnapshot, reason: UsageError)
    case throttled(previous: UsageSnapshot?, until: Date)
    case unavailable(UsageError)
}
```

三條規則，`UsageDisplayState.afterFailure` 是唯一的決定點：

- 有舊資料 → `stale`，並明示那是舊值與取得時間。
- 沒有可信資料 → `unavailable`。**未知絕不換算成 0%**。
- `throttled` 仍是共用顯示能力，但目前 live provider 不一定拿得到明確的 429 或恢復時間：Claude CLI 可能退回快取，Codex 則回 typed App Server error。只有上游真的提供可靠恢復時間時才可使用此狀態。

## 5. 為什麼有些東西不共用

| 層級 | 是否共用 | 理由 |
|---|---|---|
| 量表視覺語言 | **必須** | 同一個圖示，兩套外觀使用者無法解讀 |
| 顏色的百分比刻度 | **必須** | 各採各家判定會讓同一個顏色代表不同的事，見 [UI_SPEC.md](UI_SPEC.md) §3 |
| 狀態語意 | **必須** | 需要同一套心智模型 |
| 詳情面板資訊架構 | 建議 | 可各自擴充 |
| Provider 缺漏欄位的原因與文案 | 各自決定 | 同樣是 `nil`，Claude 的已觀察 gap 與 Codex 的 optional App Server 欄位並不是同一件事 |
| 資料取得、憑證處理 | 不需要 | 技術現實差異極大 |
| 輪詢與退避參數 | 各自設定 | 生命週期與失敗模式不同，值可以相同但理由不可混用 |

`BackoffPolicy` 仍是 per-provider instance，只保留 `initial`、`multiplier` 與 `cap`；`RetryBackoff` 負責連續失敗後的指數等待。現行 Claude CLI 與 Codex App Server provider 都不會產生舊 HTTP `Retry-After` 訊號，因此舊 HTTP 路徑的 padding、兩小時 cap 與懲罰窗 invariant 已從 shipping code 移除。

## 6. Provider 共用契約

共用層只保存兩家確實需要一致的契約：

| 契約 | 內容 |
|---|---|
| `UsageProvider` | 最小取得邊界，只有 `fetch()`；不強迫兩家共享傳輸或生命週期 |
| `UsageSnapshot`／`UsageWindow` | Provider 專屬資料轉成共用 UI 能理解的百分比、時間窗與選填詳情 |
| `UsageMeterCore/Model/UsageDisplayState.swift` | 狀態語意；`throttled` 是保留能力，目前不是 Claude live 路徑的可靠輸出 |
| `UsageMeterCore/Gauge/GaugeStyle.swift` | 填色等級、外框樣式、身分線索、VoiceOver 文案 |

`UsageProvider` protocol 是兩個 live provider 與共用 presenter 的最小邊界，現在只要求 `fetch()`。Provider 身分由 Presenter 與回傳的 `UsageSnapshot` 各自在真正需要的位置持有；失敗退避也由 Presenter 擁有，不再要求 provider 物件重複回報無人讀取的 `provider`／`backoffPolicy`。

Snapshot 不再保存無人讀取的 schema key 名稱或已退役 HTTP rate-limit headers。Decoder 遇到 schema 錯誤時只產生 App 自己寫的固定分類，不列舉 provider 控制的 JSON key；舊 Snapshot 多出的這兩個 Codable 欄位會被忽略並可正常還原。

`UsageWindow` 也不保存沒有 UI 或診斷消費者的上游 `severity`；Gauge 顏色只由正規化後的已用百分比決定。Codex 真正顯示給使用者看的原始限制狀態仍由 Snapshot 的 `rateLimitReachedType` 保存，兩者不可混為一談。舊 Snapshot 多出的 `severity` 同樣會被 Codable 忽略。

視覺語言的完整規格見 [UI_SPEC.md](UI_SPEC.md)。

## 7. 並行模型

`AppModel` 與 `ProviderPresenter` 是 `@MainActor`。Provider 是 `Sendable` struct，`fetch()` 在非隔離的 async 環境執行。Claude 每次查詢由 `ClaudeProcessRunner` 啟動短命程序；`CodexAppServerClient` 是 actor，序列化 request ID、stdin 寫入、JSONL buffer、路徑切換與 process 結束。`FileHandle` 的同步 stdout callback 先經 lock-protected `CodexOutputIngress`：同一 generation 最多一個消費者，片段依 callback 順序合併，排隊 bytes 超過 4 MB 就 fail closed。這道前置上限不可由 actor 內的 JSONL buffer 取代，因為後者看不到尚在 executor 前等待的資料。

兩種子程序都不得繼承 GUI App 的目前目錄。LaunchServices 啟動的 App 通常以 `/` 為 cwd；CLI 若把它當成專案初始化，可能檢查根目錄下的自動掛載點並觸發與額度查詢無關的 macOS「檔案與檔案夾」權限。每次啟動前，`ProviderProcessWorkingDirectory` 會在目前使用者的 macOS 暫存區建立新的 provider-specific 空白目錄，確認它位於本機 volume、不是 symlink、權限為 `0700`，再同時設定 `Process.currentDirectoryURL` 與 `PWD`。任何檢查失敗都讓該次查詢 fail closed，絕不退回 `/`、home 或目前專案。

App 本身也有單一執行個體邊界。`AppInstanceCoordinator` 在使用者專屬的 macOS 暫存區開啟固定 lock file，確認它是目前使用者擁有的普通檔案，再以核心的 non-blocking exclusive lock 原子選出唯一 owner。後開副本拿不到鎖時，只要求既有 App 顯示設定並在建立 provider 前退出；不得依 PID 大小猜啟動先後，也不得終止 peer。檔案可以留在暫存區，但鎖跟著開啟的 file descriptor；owner 正常退出或 crash 時，核心都會自動釋放，不會形成永久卡死。

`MainActor.assumeIsolated` 是**斷言不是切換** —— 它主張呼叫者已在主執行緒上，錯了就 trap。在核心的憑證讀取路徑上用它，造成過一次已建置成品的當機（來龍去脈見 [VERIFICATION.md](VERIFICATION.md)）。因此：

- `UsageMeterCore` 全面禁用 `MainActor.assumeIsolated`（`verify.sh` 護欄）。
- App 層只在**確定**於主執行緒的 callback 使用它（`queue: .main` 的通知、main 上的 timer）。KVO callback 不算，那要先 `DispatchQueue.main.async`。

`verify.sh` 雖然建置真正的 shipping target，但不用它的 bundle identity 執行 AppKit 診斷。腳本會複製臨時 App、換成唯一 bundle identifier 並 ad-hoc 重簽；因此 `UserDefaults.standard`、`UsageSnapshotStore` 與 `NSStatusItem` autosave 都落在測試身分。正式設定的指紋在診斷前後必須一致，測試 domain 必須清除；臨時 App 在 `trash` 可用時移入垃圾桶，否則驗證器明確回報保留路徑。

## 8. 落地資料

用量資料方面，除了設定值，App 只保存**每個供應商最近一次的讀數**（`UsageSnapshotStore`，寫在 `UserDefaults`）。

這不是當初排除的那種持久化。原本的規則是「不存歷史取樣、不畫時間序列、不做用量預測」，那條仍然成立 —— 這裡永遠只有一筆，每次查詢覆蓋掉前一筆，沒有任何序列可言。

它存在的理由是限流：App 原本什麼都不留，所以**每次啟動都會立刻發一次請求**。關掉再開十次就是十次請求，而輪詢排程幫不上忙，因為新的行程從空的排程開始。現在啟動時先拿出上次的讀數，只有在它超過輪詢間隔時才去查。

落地的內容是百分比、時間窗、時間戳，以及詳情面板已顯示的 Credits／plan／來源版本等非敏感欄位。Provider 提供的顯示文字在 live decoder 先限制為每欄最多 512 UTF-8 bytes，拒絕控制字元與會改變閱讀方向的格式字元；語意用的 `limitId` 另採 128-byte ASCII 識別字規則。App 不讀 Claude credential；Codex token 完全不離開 App Server。示範用的 fixture 讀數也不會被保存，否則重開之後會看到合成資料裝成真實讀數。

查詢失敗另由 `DiagnosticLogStore` 保存一份有界紀錄。資料只包含 App 產生的 UUID、發生時間、`ProviderKind` 與封閉的 `DiagnosticErrorKind`；`UsageError` 的 associated string、原始回應、JSON key、RPC message、stdout／stderr、執行檔路徑及 provider metadata 都不能進入紀錄。預設保留 5 天，使用者可選 3／5／7 天並隨時清除；改期限、啟動與新增時都會 prune，另固定最多 200 筆。只有通過 configuration-generation guard 的正式 fetch failure 記一筆，pacing skip、舊設定的晚到結果及 malformed Codex advisory push 都不記錄。

磁碟上的 JSON 是另一個輸入邊界，不能因為它曾由 App 寫出就永遠信任。保存與讀回都限制單一 snapshot 最多 64 KiB，並重新驗證所有 provider metadata；讀回時還會確認百分比有限且位於 `0...100`、storage key 與 snapshot provider 一致、來源屬於該 provider、不是 fixture、至少有一個時間窗，而且 `fetchedAt` 不在未來、所有有 reset 的時間窗仍未跨過 60 秒寬限。任一條失敗就當作沒有保存讀數並照常查詢。現行 `.claudeCodeCLI` 快照還必須各有一個 session 與 weekly window，session 缺 reset 只允許 `0%`，weekly 一律要有 reset，與 live decoder 的 fail-closed 規則相同；額外的未知 window kind 可以保留，但仍受文字與 snapshot 大小上限約束。Codex 的 reset 仍依 App Server schema 維持 optional，不套用 Claude 規則。舊 Claude `usageEndpoint`／`messagesFallback` 來源仍可解碼與短暫還原，保留升級相容性，但目前 provider 不會再產生它們。

## 9. 查詢節流

`FetchPacing` 決定一次 `refresh()` 到底送不送請求。它接受一個明確的**查詢理由**，區分排程與使用者手動要求。

| 理由 | 受輪詢間隔限制 | 受 20 秒底線限制 |
|---|---|---|
| `scheduled`（計時器） | 是 | 是 |
| `manual`（按重新整理） | 否 | 是 |

- **比輪詢間隔新的讀數就繼續用**，並且只把計時器排到剩餘時間，不是重新計時 —— 否則一直重開會讓更新無限期延後。
- **20 秒底線**涵蓋排程看不到的路徑：重開、喚醒、解鎖，以及有人因為數字沒動而連按重新整理。
- **手動查詢不受間隔限制。** 按下按鈕的人有他的理由，用計時器沒到當作拒絕的藉口，那個按鈕就是騙人的。

App 不代替使用者執行任何登入或換票指令，因此沒有 credential-change 特例。未登入時只複製 `claude`，讓使用者自行啟動 Claude Code；完成後以一般「重新整理」重新查詢，仍受 20 秒防連點底線保護。

Provider 設定改變時，`ProviderPresenter` 會推進自己持有的 configuration generation。每次查詢先記住開始時的 generation；回來時若已不同，成功與失敗都直接丟棄，不得改 UI、最近 snapshot、退避或排程。若查詢途中又收到手動更新要求，這個意圖會保留，待既有查詢結束且 20 秒底線允許後再執行，而不是被 `isFetching` 吃掉。

切換 enabled 或 executable path 只刷新受影響的 provider。Codex 換路徑需要先停止長駐 App Server，因此另用同一代的 token 約束非同步 stop；舊 stop 任務不會在新設定生效後再終止或刷新它。這個邊界由獨立 App-state transition diagnostic 驗證，正式 bundle 不允許執行該診斷旗標。

## 10. Codex App Server 生命週期

`CodexAppServerClient.shared` 是 App 內唯一的 Codex 子程序 owner。第一次 `fetch()` 時定位 CLI、以固定 arguments 啟動、完成一次 initialize handshake；之後的查詢共用同一條連線。`account/rateLimits/updated` 由 `AsyncStream` 送回 Codex presenter。

每個 App Server generation 也擁有自己的 stdout ingress。readability callback 只把 bytes 放進有界 FIFO；只有 idle 轉為 scheduled 時才建立一個 consumer，consumer 依序交給 actor。停止、重連或 overflow 會關閉該 ingress 並立刻釋放仍排隊的 bytes，舊 generation 不能再送出 result 或 notification。

每個 App Server instance 擁有自己唯一的空白工作目錄。正常停止、timeout、路徑切換或意外退出時，目錄都跟著該精確 `Process` 保留到 Foundation 確認 root child 已退出後才清理；重連建立新的目錄，不會讓新舊程序共用或提前刪除仍在使用的 cwd。

Decoder 可以接受只有 primary 的 sparse 通知；`CodexRateLimitUpdatePolicy` 只把通知實際提供的 window／metadata 合併進上一份完整 snapshot。Presenter 保留原 display-state case 與完整 read 的 `fetchedAt`，保存合併後 snapshot，但不重設 failure／backoff，也不重新安排 10 分鐘 safety poll。沒有可信 base 或 identity 不相容時，局部通知不改變現況。

`RateLimitWindow` 的 `usedPercent`、`windowDurationMins` 與 `resetsAt` 依 App Server schema 都是整數。Provider 邊界只接受 `0...100` 的整數 `usedPercent`；後兩欄可缺少或為 `null`，但有值時不得截斷小數。異常資料回 `schemaChanged`，不進入 domain model；`UsedPercent` 的 clamp 仍保留為已建立 domain value 的最後一道 UI 防禦。共用 schema 錯誤文案保持 provider-neutral，不會把 Codex 問題誤說成 Claude `/usage` 問題。

使用者切換 Codex CLI 路徑、停用 Codex 或結束 App 時會呼叫 `stop()`。停止只持有 `Process` 建立的精確 instance，不掃描或終止 Codex Desktop、Codex CLI 的其他程序。意外退出或 request timeout 都會讓 owned connection 失效；timeout request 保留精確錯誤，其他 pending request 以 connection unavailable 結束，下次 fetch 啟動新程序並重新 handshake。停止先送 `SIGTERM`，短暫 grace 後仍在執行才對該精確 root PID 送 `SIGKILL`；舊程序在觀察到 exit 前仍由 client 持有，不會因重試遺失 ownership。App 結束時先凍結排程、取消並等待 provider fetch，再等 Foundation 確認所有 owned Codex root 已退出，最後才回覆 AppKit 可以離開。

Codex JSON-RPC 的 `error.message` 是不可信的 provider 診斷，只能用來分類「未登入／版本不相容／一般失敗」。介面只顯示 App 自己寫的固定訊息與數字 error code，不顯示、保存或記錄原始 message。

## 11. AppKit 視窗與選單列邊界

`StatusBarController` 同時負責「provider 是否啟用」與「目前畫在哪一個 `NSStatusItem`」的轉譯。合併模式沒有個別 status item 是正常結構，不能因此回報未啟用；啟用且共用項目在畫面上時，設定頁顯示「合併圖示中」。

popover 開啟前先以不捲動的 SwiftUI view 測量自然高度。螢幕可用高度足夠時直接完整展開，只有自然高度超過可用範圍才換成 `ScrollView`。底部的重新整理、設定與結束 App 動作固定留在捲動區之外。

設定視窗可重用，但加入 `moveToActiveSpace`；重新開啟時跟隨目前 Space，而不是切回第一次建立視窗的桌面。這些 AppKit 行為由 `--selftest` 驗證結構契約，實際多桌面切換仍列為人工驗收項目。

## 12. Claude `/usage` 解碼與子程序生命週期

`/usage` 把百分比與 reset 包在人類閱讀的文字裡。Decoder 必須同時讀到 session 與 weekly，並逐一確認 reset 尚未超過 60 秒寬限；任何一個窗已結束，整份快取就不可用。session 缺少 reset 只在明確為 `0%` 時接受，任何非零值都 fail closed；weekly 仍一律要求 reset。文字指定的 IANA timezone 是資料契約的一部分，無法辨識時直接 fail closed，不使用本機或呼叫端時區猜測。

與 Codex 相反：**每次查詢一個新的短命子程序，不長駐。** `/usage` 是一次性回答，沒有 handshake 也沒有推播，維持一條連線只會多一個要管的失敗狀態。

每次 Claude 查詢也建立一個新的空白私人工作目錄；`/usage` 完成、失敗、逾時或取消並確認 child 結束後立即清理。它只改 cwd 與 `PWD`，不改 `HOME`，因此 Claude Code 仍使用自己的登入與全域設定，但不會把 `/`、App 安裝位置或使用者正在工作的 repository 當成這次查詢的專案。

`ClaudeUsageCommand.arguments` 是常數，沒有設定介面餵它，也沒有任何回應能影響它。執行時 stdin 接 `/dev/null`、stdout 與 stderr 各自有位元組上限並與 `waitUntilExit()` 併行讀取（先等結束再讀，輸出一超過 pipe buffer 就會死鎖）。`ByteSink` 的 buffer 由 lock 保護；hard deadline 從另一條 queue 關閉 read end 時，drain 以預期的 read failure 結束。

逾時 30 秒後先對自己建立的精確 root instance 送 `SIGTERM`；1 秒 grace 後仍在執行才用該 `Process` 當下的 PID 送 `SIGKILL`，同時關閉本 App 持有的 stdout／stderr read ends。取消若早於 `ProcessHandle.adopt` 會被記住，child 一被採用就立即進入同一套停止流程。第一個停止原因優先，所以取消回 `CancellationError`，timeout 保留 `claudeCommandTimedOut`。

App 不掃描 `claude`、不殺 process group，也不保證清理 child 刻意留下的完全獨立 descendant；它保證的是自己的查詢不會因 descendant 持有 pipe 而無限等待。這避免誤殺使用者自己啟動的 Claude CLI。

stderr 只讀來**分類**失敗（版本太舊／未登入／其他），內容不進 UI、不進 log、不進錯誤訊息 —— CLI 的診斷可能帶專案路徑、工作目錄或憑證。

`verify.sh` 有三道靜態護欄：只有 `ClaudeUsageCommand.swift` 可以建構 `Process`、arguments 清單逐字比對、`Claude/` 下不得出現 `doctor`／`mcp`／`auth`／`login` 或 shell。

## 13. 文件責任

[VERIFICATION.md](VERIFICATION.md) 保存現行驗證範圍與重要修正的回歸證據，[ROADMAP.md](ROADMAP.md) 只保留目前能力與未來工作。這份 Architecture 只描述 shipping code 現況，不重複維護內部 review 或 changelog。
