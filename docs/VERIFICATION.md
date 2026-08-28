# Verification

權威入口是：

```bash
./scripts/verify.sh
```

這個入口會建置真正的 Xcode App target，但 **AppKit 診斷不會在正式 bundle identity 下執行**：

1. 複製 unsigned Debug App 到 `mktemp` 建立的臨時目錄。
2. 將副本改成唯一的 `io.github.sean.AgentUsageBar.verification-<pid>` bundle identifier，再 ad-hoc 重簽與驗簽。
3. 只從副本執行 `--selftest`、`--instance-lock-hold`、`--render-popover` 與 `--render-sheet`。因此 App 設定、最近讀數與 AppKit `NSStatusItem` autosave 都落在測試 domain；兩個同時啟動的 lock fixture 也不建立 provider。
4. 診斷前後比對正式 provider 設定的匿名 SHA-256 指紋；不輸出偏好值或 CLI 路徑。若有漂移就失敗，**不把備份覆寫回可能正在使用的正式 domain**。
5. 無論成功或中途失敗，EXIT trap 都會清除測試 preference domain、停止仍在執行的精確 fixture child，並以 `trash` 清理臨時 App 與隔離 lock file；清理工具不可用或失敗時會明確回報保留路徑。

不要直接從日常安裝的 `AgentUsageBar.app` 手動執行 `--selftest`；權威腳本已經自動完成比手動流程更完整的隔離與清理。

正式 App 自 2026-08-26 起使用 `io.github.sean.AgentUsageBar`。下方較早驗證節點若出現 `com.sean.AgentUsageBar`，是當時實際使用的舊身分，不是目前設定。

## 檢查項目

| 步驟 | 檢查什麼 | 為什麼需要它 |
|---|---|---|
| `swift test` | 核心邏輯單元測試 | 百分比、刻度、兩家解碼器、`/usage` 文字剖析與重置時間格式、新鮮度守門、JSONL／JSON-RPC、退避、狀態轉移、失敗分類、安全登入指引、雙語呈現、隱私安全的診斷紀錄，以及舊版快照相容性與損壞快取拒絕 |
| Debug／Release `xcodebuild` | Debug 診斷 App 與**實際出貨的 Release App target**（不簽章） | package 不編譯 App 層，`swift build` 看不到它；Debug 通過不能代替 Release。刻意不簽，避免要求驗證者先有憑證 |
| Release fixture guard | Xcode target metadata 與 Release binary 都不得含 fixture module／型別／UI 文案 | 合成 render 情境可留在 `#if DEBUG`，但 DMG 不應附帶假資料模式 |
| bundle sanity | 圖示存在、`LSUIElement` 已設 | 沒設 `LSUIElement` 的選單列 App 啟動後看起來什麼也沒做 |
| atomic single-instance fixture | 從唯一 bundle ID 同時啟動兩個不建立 provider 的 Debug 副本，確認只有一個持有核心鎖、另一個自行退出 | PID 會循環，也不能代表啟動先後；只有原子的 ownership 能防止兩個隱形 App 同時輪詢 |
| status bar selftest | 從唯一 bundle ID 的診斷 App 真正建立 `NSStatusItem`，驗證合併位置、目前 Space 與 popover 捲動決策 | 編得過不代表 AppKit 接線符合使用者看到的狀態；production preferences 不得成為測試 fixture |
| live path smoke | 非主執行緒跑完整 `fetch()`：缺執行檔、成功解碼、讀數過期三條路徑，全用 stub 程序 | 這是並行與錯誤路徑驗證，不啟動任何 CLI、不查詢真實帳號 |
| 子程序執行器測試 | 用系統內建指令與中性 fixture 實際啟動程序，驗證 stdout、非零 exit、stdin、輸出上限、adopt 前取消、抗拒 `SIGTERM`、descendant-held pipe，以及真實 cwd／`PWD` | 兩個 provider 都必須對自己建立的精確 root child 有 deadline；每個 instance 也必須從新的空白、本機、`0700` 暫存目錄執行，退出後精確清理，且建立失敗不得退回 `/`。測試 descendant 只用 UUID stop capability 自行退出，不從檔案讀 PID 後送訊號 |
| UI render check | 強迫 SwiftUI 面板與設定視窗跑真正的排版 | 驗證繁中／英文、合併內容完整展開、深淺色與實際像素輸出 |
| gauge contact sheet | 所有狀態 × 淺色深色 | 視覺語言的人工檢查依據 |
| packaging preflight fixture | 在臨時 Git repo 證明乾淨 commit 可通過且不改 source；增加無關 commit 後版本／build 不變；dirty tree、metadata override 與缺少 exact plan 的完整打包會被拒絕 | Build 必須來自 committed metadata，不能成為 Git 歷史重寫的人質；候選成品不能繞過版本交易 |
| release transaction fixture | 在隔離 Git repo 證明 plan 完全只讀、第一個公開候選必須明確選 next minor，且 prepare 只 commit `Version.xcconfig` 並留下 transaction record | 發布工具本身會 commit，因此要用可丟棄 repo 驗證 mutation scope、readback 與版本政策，不能在正式 repo 試錯 |
| guard: GitHub Actions | workflow 固定 `macos-26`／Xcode 26.6、read-only checkout、不保留 credentials、不用 secrets／`pull_request_target`，並直接呼叫 `./scripts/verify.sh` | CI 應驗證陌生 clone，不應取得 push 或外部帳號權限，也不應分叉成另一套測試流程 |
| guard: public tree | gitignored 本機 skills、handoff、內部計畫與研究筆記不得仍受追蹤；退役的 `spike-d1.sh` 不得存在 | 公開 repository 只包含產品、測試與使用者需要的文件，不把私人協作紀錄或 credential 實驗一起發布 |
| guard: retired path | 出貨 source 不得再出現 `api/oauth/usage`、鑰匙圈讀取、`claude-cli/` 冒充或已移除的換票型別 | 走回舊路等於把整片風險面一起帶回來，那應該是設計討論的結論，不是 diff 的副作用 |
| guard: core isolation | 核心不得有 main-actor 假設 | 見下 |
| guard: retired `PollPolicy` | 正式 Swift source 不得重新出現沒有消費者的第二套輪詢間隔 | 排程的單一事實來源是 `RefreshInterval`，請求底線由 `FetchPacing` 負責 |
| guard: retired HTTP backoff | 正式 Swift source 不得重新出現舊 endpoint 的 padding、兩小時 cap 或懲罰窗欄位 | live providers 沒有這些訊號；一般指數 `RetryBackoff` 仍保留 |
| guard: fetch-only provider | `UsageProvider` 與兩個 live provider 不得重複暴露 Presenter 擁有的 provider／backoff metadata | protocol 只描述呼叫者真正需要的 `fetch()`；Snapshot 的必要身分不受影響 |
| guard: unconsumed diagnostics | 正式 source 不得重新出現未使用的 access-outcome helper、Snapshot schema-key 或 retired-header 欄位 | Decoder 可在錯誤當下使用 key 名稱，但不把零消費者診斷資料持久化 |
| guard: unused upstream severity | 正式 source 不得重新加入 `UsageSeverity` 或 `UsageWindow.severity` | Gauge 只看百分比；Codex 可見的 `rateLimitReachedType` 另行保留 |
| guard: unsupported Extra Usage | 正式 source 不得重新加入 `extraUsageEnabled` 或已移除的顯示列 | 兩個 live provider 都沒有穩定唯讀來源；帳務變更指令另由 Claude command guard 禁止 |
| guard: Codex read-only | 出貨 source 不得出現登入、登出、consume reset credit 或寄信方法 | Codex provider 的授權邊界是帳號唯讀 |
| guard: Claude command | 只有 `ClaudeUsageCommand.swift` 可建構 `Process`；arguments 清單逐字比對；`Claude/` 下不得出現登入／維護指令、shell，或 `usage-credits`／`extra-usage` | 後兩者帶有購買、申請或開啟額外計費的語意，不得拿來探測資料 |
| guard: no `rm` | 腳本刪檔一律用 `trash` | 刪錯要救得回來 |
| `git diff --check` | 空白字元問題 | |

## 最近驗證節點

這裡保留行為與驗證結果，不引用公開前的內部 commit hash。公開基線以可重跑的 `./scripts/verify.sh`、現行 source 與測試作為長期證據。

2026-08-28，公開前標準安全掃描與收尾：安全掃描完整檢視 95 個 tracked files，確認沒有 token、私鑰、個人 email、Apple Team ID 或簽章 identity；三項 low finding 已修正。Provider 控制的顯示文字限制為 512 UTF-8 bytes，語意識別字限制為 128-byte 安全字元，保存 snapshot 限制為 64 KiB，live decoder 與保存層都會拒絕不安全輸入；focused 測試先在舊行為紅燈，修正後 28 項全綠。公開文件移除真實帳號百分比、精確 reset／查詢時間與不必要的 retired credential 細節，保留合成格式與設計結論。重複啟動不再終止同 bundle peer，也不以 PID 大小猜先後；使用者專屬暫存區的核心 exclusive lock 原子選出唯一 owner，兩個同時啟動的隔離 App 證明只有一個留下，另一個在建立 provider 前退出。發布 transaction 另做防誤用加固：第一次 tag 仍要求 manifest／DMG／packaged transaction 全部吻合，成功後 exact annotated tag 可在 ignored `tmp/` 已清理時完成冪等 readback，tampered manifest 仍被拒絕。完整 `./scripts/verify.sh` 通過 172 項／22 suites、Debug／Release Xcode builds、原子單例 fixture、隔離 AppKit diagnostics、provider transition shutdown、雙語 settings／popover render、production settings unchanged、packaging／release fixtures、全部靜態安全護欄與 `git diff --check`。沒有執行真實 provider、查詢帳號、建立 DMG、tag、push、Git reset 或遠端 release。

2026-08-28，Codex stdout bounded ingress 與測試 PID 清理：舊 `readabilityHandler` 每個 callback 都先建立一個未受限 Task，actor 內的 JSONL 4 MB cap 看不到前面排隊的 Task／Data，也沒有程式層 FIFO 契約；新 `CodexOutputIngress` 以 lock 保護單一合併 buffer，同一 generation 最多一個依序 consumer，排隊 bytes 超過 4 MB 時在建立新工作前 fail closed，停止或換代立即丟棄舊資料，consumer 每批 yield 避免持續輸出獨占 actor。十萬個一位元組 callback 只啟動一個 consumer。獨立 patch review 另找到「3.5 MB partial line 加上以換行開頭的後續合法批次」會被暫時合計大小誤拒；紅燈重現後，JSONL 改以線性掃描分別限制每一完整行與最後未換行尾端，合法多行通過、單一超過 4 MB 仍拒絕。Claude process fixture 原本從暫存檔重讀 bare PID 後 `SIGKILL`；紅燈 guard 命中舊路徑後，fixture 改由 UUID state path 衍生 stop／done capability 自行退出，測試完全不解析 PID、不送 signal，另以永久靜態 guard 防止回歸。Focused Codex JSONL 12 項、Codex lifecycle 4 項與 Claude process runner 11 項通過，沒有 fixture state／stop／done 殘留。完整 `./scripts/verify.sh` 通過 168 項／22 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、雙語 settings／popover render、production settings unchanged、packaging／release fixtures、全部靜態安全護欄與 `git diff --check`。沒有執行真實 provider、查詢帳號、建立 DMG、tag、push 或遠端 release。

2026-08-28，錯誤診斷隱私邊界與使用者可見紀錄：兩個 decoder 不再把 provider 提供的 JSON key 名稱帶入錯誤或修復文字；設定新增獨立「診斷紀錄」頁，只保存 App 自己定義的供應商、時間與固定錯誤類型。原始回應、credential、執行檔路徑與 `UsageError` 的關聯文字一律不進紀錄。保存期限可選 3／5／7 天、預設 5 天，變更後立即清除過期與未來時間紀錄，另有 200 筆硬上限；「清除紀錄」只刪錯誤紀錄，不動期限選擇、用量快照或 provider 設定。惡意 key marker 不會出現在英文或繁中 remedy，provider 任意字串也不會出現在持久化 bytes；期限、損壞資料、未來時間、容量上限與清除邊界均有單元測試。完整 `./scripts/verify.sh` 通過 162 項／22 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、雙語 settings／popover render、production settings unchanged、packaging／release fixtures、靜態安全護欄與 `git diff --check`。第一次在受限沙盒執行只因無法寫入使用者 Swift module cache 而停止；授權同一權威腳本使用正常快取後全綠。沒有執行真實 provider、查詢帳號、建立 DMG、tag、push 或遠端 release。

2026-08-28，保存快照與發布文件兩項 P1：舊保存層先在四個 assertion 紅燈，證明 `.claudeCodeCLI` 的非零 session 缺 reset，以及 weekly 缺 reset，都能從 `save` 與手動注入的 defaults 繞過 live decoder。修正後現行 Claude CLI 快照各須一個 session／weekly window，session 缺 reset 只允許 `0%`，weekly 一律需要 reset；Codex optional reset 與退役 Claude source 相容性保持不變。Claude 後續複核確認四條規則與 live decoder 一致；新增端到端測試讓一般 session 與 `0%／nil reset` 的 decoder 產物都必須能保存，另證明 `.claudeCodeCLI` 可保留額外未知 window kind，且兩種非法快照在 `save` 階段完全不寫入 defaults。發布文件則以 `Version.xcconfig` 和即時 plan 為權威，正常下一個候選使用 `release.sh plan`／`prepare`，不再把歷史遷移用的 `--next-minor` 寫成目前指令；release automation 長文件縮成不含可變現況的設計紀錄。Focused snapshot 17 項通過；完整 `./scripts/verify.sh` 通過 156 項／21 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、雙語 render、production settings unchanged、packaging／release fixtures、全部靜態護欄與 `git diff --check`。第一次完整驗證只因沙盒不能寫 Swift module cache 而停止，授權同一權威腳本使用正常使用者快取後全綠；沒有執行真實 provider、查詢帳號、建立 candidate DMG、tag、push 或遠端 release。

2026-08-28，Claude 離線跨窗與 provider 呈現邊界：只有 Wi-Fi 的測試機關閉 Wi-Fi、跨過已知 session reset 並等過 60 秒寬限後，`/usage` 回傳上一個窗的非零百分比與舊 reset；恢復 Wi-Fi 後再次查詢才回傳 `0%`、無 reset 的新窗形狀。實驗腳本使用仍留在路由表裡的預設路線而誤標 `net=online`，確認路由項目與 `duration_ms` 都不能當連線證據。程式新增 fail-closed 規則：Claude session 缺少 reset 只接受明確 `0%`，非零值拒絕；詳情列只共用排版，Claude 的已觀察 gap 與 Codex optional reset 各自決定文案。新增的非零缺 reset 測試先如預期失敗，修正後 Claude decoder 27 項全綠；完整 `./scripts/verify.sh` 通過 150 項／21 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、新增的 Claude 空窗深淺色 render、雙語 render、production settings unchanged、packaging／release fixtures、全部靜態護欄及 `git diff --check`。另人工檢視 `dist/ui.png`，英文空窗文案未擠壓或跑版。完整 verifier 沒有執行真實 provider、查詢帳號、建立 DMG、tag、push 或遠端 release；跨窗證據仍限單一樣本與單一 Claude Code 版本。

2026-08-27，provider 子程序工作目錄隔離：實機記錄確認舊版 App 啟動 Claude Code 時沿用 `/`，並由 Claude Code 的檔案存取觸發 macOS「網路卷宗」權限詢問。修改前的紅燈測試也證明 Claude 與 Codex 會沿用 package 工作目錄，Codex 重連時還會重複使用同一路徑。修正後兩個 provider 每次啟動都使用各自新建的本機、空白、非符號連結、權限 `0700` 的使用者暫存目錄，同步設定 cwd 與 `PWD`，子程序退出後只清理自己持有的精確目錄；建立或驗證失敗一律停止，不退回 `/`、家目錄、App 所在位置或 repository。修改前另從相同設計的空白使用者暫存目錄各執行一次真實 Claude `/usage` 與 Codex `account/rateLimits/read`，兩者均成功、未保存 raw response，測試期間沒有新的 Network Volumes TCC 記錄。Focused lifecycle／working-directory tests 通過 17 項／3 suites；完整 `./scripts/verify.sh` 通過 149 項／21 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、雙語 render、production settings unchanged、packaging／release fixtures、全部靜態護欄及 `git diff --check`。沒有建立新 DMG、tag、push 或遠端 release；仍需以包含本修正的新 DMG 從 `/Applications` 手動查詢一次，確認 App attribution 下不再出現該權限詢問。

2026-08-27，committed release transaction：版本、build 與 suffix 收斂到 `Version.xcconfig`，Xcode project 不再重複保存版本，build 不再依賴 Git commit count。新的 `release.sh` 先提供完全只讀 plan，再以單一 lock、完整 verifier、精確版本 commit 與一次性 transaction plan 授權低階打包；`package_dmg.sh` 沒有 exact plan 時不能建立 DMG，同名輸出不覆蓋，並讀回 built／mounted App 的版本、suffix、source commit、實際架構與 signer後產生 checksum 和 candidate manifest。Finalize 只接受 exact manifest，重驗 candidate 後建立本機 annotated tag，重複同一 finalize 為 idempotent，既有不同 tag 不移動。隔離 fixture 證明 `0.3.2 --next-minor` 對應 `0.4.100 (4100)`、無關 commit 不改 build、plan 不改 HEAD／tree／refs／working tree、prepare commit 只有版本檔，finalize 精確指向 candidate commit。完整 `./scripts/verify.sh` 三次通過 146 項／20 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、雙語 render、production settings unchanged、packaging／release fixtures、全部靜態護欄及 `git diff --check`。沒有執行真實 provider、建立候選 DMG、tag、push 或遠端 release。

2026-08-27，公開邊界與結束流程修正：標準 security scan 完整檢視 87 個 tracked files，兩項 reportable finding 均在本批修正——打包不再透過呼叫者 `PATH` 尋找 release-critical 工具，並清除單次 Xcode selector override；公開文件不再把 ad-hoc 簽章誤稱為開發憑證，且區分 checksum、發布者身分與尚未實測的第三方 Gatekeeper 流程。兩項另外確認的 correctness 問題也一併修正：跨啟動 snapshot 會拒絕未來 `fetchedAt` 或任何已跨 reset 的窗，App 結束則凍結 presenter、取消並等待 fetch，以及等到抗拒 `SIGTERM` 的 exact owned Codex process 真正退出後才回覆 AppKit。Focused snapshot 11 項與 Codex lifecycle 4 項通過；完整 `./scripts/verify.sh` 通過 146 項／20 suites、Debug／Release Xcode builds、隔離 AppKit diagnostics、provider transition shutdown、雙語 render、production settings unchanged、tracked-source packaging fixture、新 release trust guard 及 `git diff --check`。沒有執行真實 provider、查詢帳號或建立新 DMG。

2026-08-27，保存讀數信任邊界修正：舊程式先由四項測試紅燈，證明範圍外 `250%`、storage key／snapshot provider 不一致、手動注入 fixture 與跨 provider source 都能被還原；同一批修正另固定空 windows 不得阻止重新查詢。`UsedPercent` 的 persisted decode 現在拒絕非有限或 `0...100` 外數字，`UsageSnapshotStore` 再驗證 provider、source、fixture 與非空 windows；既有未知 window kind 與退役 Claude source 相容性仍通過。Focused suite 9 項全綠；完整 `./scripts/verify.sh` 通過 143 項／20 suites、Debug／Release Xcode builds、全部隔離 diagnostics、雙語 render、production settings unchanged、tracked-source packaging fixture、CI／provider 靜態護欄及 `git diff --check`。沒有執行真實 provider、查詢帳號或建立新 DMG。

2026-08-27，隔離來源與簽章政策：共用 Xcode 設定改為完整的 ad-hoc／Manual／空 Team，不再 include 本機 override；打包預設不掃描憑證，只接受 ad-hoc 或明確完整的 Developer ID Application，並從 clean commit 的 `git archive` 建置。完整 verifier 與一次內部 DMG 機制驗證均通過 signer readback、`codesign --verify`、`hdiutil verify`、唯讀掛載內容檢查及 SHA-256 readback。內部成品識別與 checksum 不帶進公開文件；正式 release 應在 GitHub Release 留下對應證據。

2026-08-26，依 provider 邊界重整 Codex 文件：以目前 source、tests 與官方 Codex App Server 文件核對後，`CODEX_USAGE.md` 改為獨立記錄 stdio allow-list、欄位映射、sparse notification 合併、查詢新鮮度、process recovery、executable trust 與未驗證項目；共用 `ARCHITECTURE.md`／`SAFETY.md` 只保留兩家真的共享的契約，過時的 Codex P1 過程段落移除。Codex focused tests 通過 25 項／5 suites；完整 `./scripts/verify.sh` 通過 138 項／20 suites、Debug／Release Xcode builds、隔離 diagnostics、雙語 render、production settings unchanged、打包 fixture、CI／public-tree／provider 靜態護欄及 `git diff --check`。沒有執行真實 provider、查詢帳號或建立 DMG。

2026-08-26，公開前安全與瘦身收尾：離線掃描 98 個原預計公開檔案，確認沒有真實 token、私鑰、個人 email、本機使用者路徑、Apple Team ID 或簽章 identity；四項 low finding 分別是 Codex raw error 顯示、Codex cooperative-only 終止、退役 credential spike、以及內部 handoff／真實事故細節。程式以固定錯誤訊息與 exact-child `SIGTERM`／grace／`SIGKILL` 修正，新增 provider-error 與 TERM-resistant fixture 測試；credential spike 與過時 TODO 移到垃圾桶，本機 skills、handoff、研究／計畫文件保留但停止 Git 追蹤，公開安全文件改為一般化規則。最終共用簽章設定固定為 ad-hoc／Manual／空 Team，且不 include 本機 override。完整 verifier 通過 App、UI、隔離 diagnostics、雙語 render、production settings unchanged、打包 fixture 與靜態護欄；沒有執行真實 provider、查詢帳號、讀取 credential 或建立 DMG。

2026-08-26，移除無可靠來源的 Extra Usage surface：舊程式先在相容性測試紅燈，證明含 `extraUsageEnabled` 的舊 snapshot 仍會把該欄位寫回；移除 model、Codex decode／merge 傳遞、Debug producer、UI row 與翻譯後，同一份舊 JSON 可正常解碼且重新保存時不再帶退休欄位。永久 source guard 防止假支援回歸。完整 `swift test` 與 `./scripts/verify.sh` 均通過 131 項／20 suites、Debug／Release Xcode builds、全部隔離 diagnostics、雙語 render、production settings unchanged、打包 fixture、CI 與所有靜態護欄及 `git diff --check`。沒有執行真實 provider、帳號或帳務指令。

2026-08-26，Claude 帳務變更指令護欄：在移除 Extra Usage 欄位之前，先把 `usage-credits`、`/usage-credits`、`extra-usage` 與 `/extra-usage` 納入固定 arguments 單元測試及 shipping-source 靜態護欄；不論未來是否出現新的唯讀來源，App 都不得執行這些會購買、申請或開啟計費的指令。16 項 `ClaudeProviderTests` 通過；完整 `./scripts/verify.sh` 通過 131 項／20 suites、Debug／Release Xcode builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、打包 fixture、CI 與其餘靜態護欄及 `git diff --check`。沒有執行真實 provider、帳號或帳務指令。

2026-08-26，取消排程顯示一致性修正：App-layer self-test 先在舊程式重現兩項紅燈，暫停與停用都已取消 timer，卻仍保留 `nextAttemptAt`。修正後 `cancelScheduledAttempt()` 成為 timer invalidation、ownership 與顯示時間的單一清理入口，pause、disable／reschedule、Debug scenario、expected limitation 與 fired-timer path 共用。完整 `./scripts/verify.sh` 通過 131 項／20 suites、Debug／Release Xcode builds、三項 scheduling self-test、bundle identity、全部隔離 diagnostics 與雙語 render、production settings unchanged、打包 fixture、CI 與其餘靜態護欄及 `git diff --check`。沒有執行真實 provider 或查詢帳號。

2026-08-26，多原因輪詢暫停修正：新測試先因舊程式沒有獨立 pause-reason model 而編譯紅燈；修正後 `PollingPauseState` 分別追蹤 system sleep、display sleep 與 screen lock，只有最後一個原因解除時才恢復，重複及順序顛倒通知不改變正確狀態。Focused tests 2 項通過；App-layer self-test 同時確認重疊 sleep／lock 的暫停與最終恢復。完整 `./scripts/verify.sh` 通過 131 項／20 suites、Debug／Release Xcode builds、bundle identity、全部隔離 diagnostics 與雙語 render、production settings unchanged、打包 fixture、CI 與其餘靜態護欄及 `git diff --check`。沒有執行真實 provider 或查詢帳號。

2026-08-26，未來 fetch timestamp 修正：舊 `FetchPacing` 先在兩項測試紅燈，未來一天的 `lastAttemptAt` 產生 86,420 秒 retry，未來一天的 `storedFetchedAt` 產生 88,200 秒 freshness。修正後未來時間不再被視為可信的新鮮證據，而是允許一次修復查詢；正常的 20 秒底線、保存讀數 freshness 與手動查詢規則不變。Focused tests 12 項通過；完整 `./scripts/verify.sh` 通過 129 項／19 suites、Debug／Release Xcode builds、bundle identity、全部隔離 diagnostics 與雙語 render、production settings unchanged、打包 fixture、CI 與其餘靜態護欄及 `git diff --check`。沒有執行真實 provider 或查詢帳號。

2026-08-26，Bundle identifier 由內部測試用的 `com.sean.AgentUsageBar` 凍結為公開前最終身分 `io.github.sean.AgentUsageBar`：Xcode Debug／Release 設定、正式驗證 preference domain、隔離診斷 identity 與 DMG metadata guard 已同步更新。完整 `./scripts/verify.sh` 通過 127 項／19 suites、Debug／Release Xcode builds、Release fixture guard、bundle identity sanity、全部隔離 diagnostics 與雙語 render、production settings unchanged、打包 fixture、CI 與其餘靜態護欄及 `git diff --check`。沒有執行真實 provider、查詢帳號或遷移舊設定；當時 repository 尚未公開或推送。

2026-08-26，GitHub Actions workflow：committed tree 原先沒有 workflow，先作為紅燈；新增 `.github/workflows/verify.yml`，固定 `macos-26`、Xcode 26.6 與 `actions/checkout@v6`，權限只有 `contents: read`，checkout 不保留 credentials，沒有 secrets、`pull_request_target` 或 write scope，且唯一驗證步驟直接呼叫 `./scripts/verify.sh`。YAML 解析與靜態 CI guard 通過；完整 verifier 通過 127 項／19 suites、Debug／Release builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、打包 fixture、所有靜態護欄及 `git diff --check`。當時尚未有 GitHub hosted run，因 repository 尚未建立或推送；沒有執行真實 provider。

2026-08-26，打包版本交易修正：舊 shipping script 的 `/usr/bin/sed -i` 先作為紅燈，證明它會在 build 前改寫 `MARKETING_VERSION`。修正後版本與 source commit 只從乾淨 HEAD 讀取，版本／build override 被拒絕；建置完成後再次檢查 HEAD／working tree，並驗證 bundle 內嵌 source commit。DMG 完成 verify、唯讀掛載與 checksum 前只留在暫存區。臨時 Git fixture 證明 clean preflight 不改 source、dirty tree 與 override 會失敗；完整 `./scripts/verify.sh` 通過 127 項／19 suites、Debug／Release builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有建立正式 DMG，也沒有執行真實 provider。

2026-08-26，無消費者 upstream severity 瘦身：盤點確認 `UsageWindow.severity` 除 decoder、fixtures 與自我測試外沒有 UI 或診斷消費者；Gauge 本來就只看百分比，Codex 的 `rateLimitReachedType` 則有獨立 UI row，明確保留。修正後 54 項 focused tests 通過；舊 Snapshot 帶退休的 `severity` 仍可 decode。完整 `./scripts/verify.sh` 通過 127 項／19 suites、Debug／Release builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有執行真實 provider。

2026-08-26，零消費者 helper／Snapshot diagnostics 瘦身：盤點確認 `localizedAccessOutcome` 無呼叫者，`observedTopLevelKeys`／`rateLimitHeaders` 只有自我保存與測試，沒有 UI 或診斷消費者；`meteredLimitID` 則因 Codex push compatibility gate 明確保留。修正後 47 項 focused decoder／merge／pacing／compatibility tests 通過，且舊 Snapshot 帶兩個已移除 Codable keys 仍可還原。完整 `./scripts/verify.sh` 通過 129 項／19 suites、Debug／Release builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有執行真實 provider。

2026-08-26，fetch-only provider 契約：盤點確認 protocol／live providers 的 6 個 provider/backoff declarations 沒有消費者，UI 與保存真正需要的身分來自 Presenter／`UsageSnapshot`。精準 guard 先紅燈，修正後 `UsageProvider` 只要求 `fetch()`，Debug transition provider 也不再帶假身分。20 項 focused provider tests 通過；完整 `./scripts/verify.sh` 通過 129 項／19 suites、Debug／Release builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有執行真實 provider。

2026-08-26，退役 HTTP backoff 瘦身：盤點確認兩個 live provider 都不會產生 `.rateLimited(retryAfter:)`，永久 guard 先對 padding、兩小時 cap、懲罰窗與 invariant 的 17 個 source 命中紅燈。修正後 `RetryBackoff` 只保留每家 provider 的 `initial`、`multiplier`、`cap` 與連續失敗計數；限流 UI 狀態仍保留。20 項 focused state/backoff tests 通過；完整 `./scripts/verify.sh` 通過 129 項／19 suites、Debug／Release builds、全部隔離 diagnostics 與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有執行真實 provider。

2026-08-26，未使用 `PollPolicy` 瘦身：盤點確認 10 個 shipping-source 命中都只是宣告或轉接，真正排程只讀 `RefreshInterval` 與 `FetchPacing`；永久 source guard 先對舊程式紅燈。修正只移除該型別、protocol/provider properties 與自我測試，未改失敗 backoff。13 項 focused tests 通過；完整 `./scripts/verify.sh` 通過 134 項／19 suites、Debug／Release Xcode builds、所有隔離 diagnostics 與雙語 render、production settings unchanged、fixture 與 PollPolicy 等靜態護欄及 `git diff --check`。沒有執行真實 provider。

2026-08-26，Release fixture 瘦身：先以舊程式建立 unsigned arm64 Release，確認 executable 實際含 `UsageMeterFixtures`、`DemoScenario`、`FixtureUsageProvider` 與 synthetic settings copy；新增 verifier guard 後先在 Xcode product dependency 紅燈。修正後 shipping target 只連 `UsageMeterCore`，Presenter／設定頁沒有 fixture/live 或 Demo State，合成情境以 `#if DEBUG` 保留給 diagnostics。focused Release executable 從 3,671,392 降到 3,086,064 bytes，少 585,328 bytes（約 16%）。完整 `./scripts/verify.sh` 通過 136 項／19 suites、獨立 Debug／Release Xcode builds、fixture-free target／binary guard、所有隔離 diagnostics 與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有執行真實 provider。

2026-08-26，Codex 數字 fail-closed 修正：舊程式先在 5 個 decoder assertion 紅燈——範圍外百分比被 clamp、非整數百分比被接受、選填整數欄位被截斷；另有 2 個 JSON-RPC assertion 證明小數 request ID／error code 被截斷，雙語測試證明共用 schema remedy 錯指 Claude `/usage`。修正後三個 focused suites 全綠；本機 `codex-cli 0.149.0` 暫存 schema 確認三欄皆為 integer。完整 `./scripts/verify.sh` 通過 136 項／19 suites、shipping Xcode App target、所有隔離診斷與雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。暫存 schema 已移到垃圾桶，沒有執行真實 provider、查詢帳號或保存 raw response。

2026-08-26，Claude hard lifecycle 修正：舊程式先在三項測試紅燈——adopt 前取消變成 timeout、抗拒 `SIGTERM` 的 root 超過 3 秒界線、descendant 持有 pipe 約 5 秒後回成功。修正後 10 項 process-runner tests 全綠，兩個 hard-bound 案例約 2.1 秒結束；完整 `./scripts/verify.sh` 通過 133 項／19 suites、shipping Xcode App target、所有隔離診斷與 render、production settings unchanged、靜態護欄與 `git diff --check`。`ByteSink` Sendable warning 消失；沒有 fixture 程序或 PID 檔殘留，也沒有執行真實 provider。

2026-08-26，Claude reset/timezone fail-closed 修正：舊程式先在「weekly 已過期但 session 尚有效」與「未知 named timezone」兩項測試紅燈；修正後 focused suite 21 項全綠。完整 `./scripts/verify.sh` 通過 130 項／19 suites、shipping Xcode App target、bundle sanity、隔離 AppKit 與 provider-transition 診斷、合成 live path、雙語 render、production settings unchanged、靜態安全護欄與 `git diff --check`。沒有執行真實 provider、查詢真實帳號或保存 raw response。

2026-08-26，provider transition 修正：舊程式先在五項案例紅燈，涵蓋 Live → Fixture、Fixture → Live、Claude CLI 路徑不得刷新 Codex、舊路徑結果不得回寫，以及停用後的晚到結果不得回寫。修正後獨立的 `--provider-transition-selftest` 全部通過；正式 bundle 會拒絕此診斷旗標。完整 `./scripts/verify.sh` 連續兩次通過 128 項／19 suites、shipping App target、bundle sanity、隔離診斷、合成 live path、雙語 render、production settings unchanged、靜態護欄與 `git diff --check`。沒有執行真實 provider 或保存 raw response。

2026-08-25，診斷隔離修正：`./scripts/verify.sh` **整份原樣通過**。121 項／17 suites、unsigned Xcode App target、bundle sanity、隔離的 status-bar selftest／live-path stub smoke、英文／繁中與深淺色 render、gauge contact sheet 與所有靜態護欄均通過。正式 bundle 直接執行 `--selftest` 會依設計以 exit 2 拒絕；診斷 bundle 使用當時唯一的測試 identity。腳本回報正式 App 設定未改變，結束後另行讀回確認該 preference domain 與臨時 App 都已清除。沒有執行真實 Claude／Codex 查詢。

2026-08-25，早期 review 基準：`swift test` 121 項／17 suites 全部通過；unsigned Debug 與 Release Xcode App target 通過；`xcodebuild analyze` 通過；bundle icon、`LSUIElement` 與 plist 通過。臨時複製 App、改用隔離 bundle ID 並重新 ad-hoc sign 後，status bar selftest、live path smoke（stub）、英文／繁中與淺色／深色 render、gauge contact sheet 全部通過。唯一編譯警告是 `ClaudeUsageCommand.ByteSink` 被 `@Sendable` dispatch closure 捕捉但本身未宣告 `Sendable`。沒有執行真實 Claude／Codex 查詢。

在 review 當時，**沒有把 `./scripts/verify.sh` 原樣執行**：review 先證實它會改寫正式 preferences，因此改成逐項執行，UI 部分使用隔離 bundle。這是修正前的歷史紀錄；現在的權威腳本已完成隔離。

2026-08-23，未 commit 工作樹：`./scripts/verify.sh` 全部通過，包含 122 項測試、實際 Xcode App target 建置、bundle sanity、status bar selftest、live failure-path smoke、英文／繁中登入修復畫面，以及 Claude 登入修復不得執行 CLI 的靜態護欄。這次驗證不讀寫真實憑證，也不查詢真實帳號。

2026-08-20，早期 verifier 基準：`./scripts/verify.sh` 全部通過，包含 111 項測試、實際 Xcode App target 建置、bundle sanity、status bar selftest、UI render check、gauge contact sheet 與五道靜態護欄。

## 護欄的由來

它們不是預想的風險，是踩過的坑。

**`swift build` 看不到 App 層。** 重構之後 App 層由 Xcode target 編譯，不再是 package target。一個 SwiftUI 型別錯誤因此 `swift build` 通過、`xcodebuild` 才抓到。所以驗證必須跑真正的 `xcodebuild`。

**`MainActor.assumeIsolated` 是斷言不是切換。** 它主張呼叫者已在主執行緒上，錯了就 trap 終止程式。當時在（現已移除的）`KeychainCredentialReader.read()` 裡用了它，而 `read()` 是從非隔離的 async `fetch()` 呼叫的 —— 結果是：跳出密碼框、使用者輸入、App 當場死掉。**這個當機進到了已建置的成品**。

補救時發現 live path smoke 抓不到它：沒有鑰匙圈項目時只會走失敗分支，而當機在成功分支上，要走到成功分支就需要真實的授權對話框。所以又加了一道靜態護欄 —— `UsageMeterCore` 全面禁止 `MainActor.assumeIsolated`。核心是純邏輯、被非主執行緒的程式呼叫，那裡出現這個斷言就是等著炸。

改走 CLI 之後成功分支終於能自動化了：smoke test 用一個 stub 程序跑完整條解碼路徑，不再需要真實的授權對話框。靜態護欄仍然保留。

這兩道都實際塞回 bug 驗證過確實抓得到，不是寫完就假設有效。另外兩道（版本號不寫死、腳本不使用 `rm`）的由來分別見 [PACKAGING.md](PACKAGING.md) 與專案規範。

## 開發輔助

```bash
./scripts/verify.sh                                          # 包含隔離的 NSStatusItem 接線 + live path smoke
<App>/Contents/MacOS/AgentUsageBar --render-sheet out.png    # 量表對照圖
<App>/Contents/MacOS/AgentUsageBar --render-appicon out.iconset
```

`--selftest` 與 `--render-popover` 會建立偏好設定相關物件，因此只允許權威腳本在臨時診斷 bundle 中執行，不提供正式 App 的手動直跑方式。

## 沙盒限制

`swift build` 在受限沙盒內會失敗（`sandbox_apply: Operation not permitted`）。SwiftPM 編譯 manifest 時會自行啟動一層 sandbox，無法巢狀。**這不是 `Package.swift` 的問題** —— 在一般終端機執行即可，不要花時間排查專案設定。

## 尚未涵蓋

- **真實 `/usage` 輸出的解析（自動化部分）。** 已於 2026-08-24 實機確認格式與數值正確，但自動化測試只跑合成 fixture —— 真實輸出含使用者的本機活動統計（用了哪些 skill、哪些 MCP server），不適合進版控。
- **Codex 真實帳號回應（自動化部分）。** decoder 與 process client 依官方文件及本機 `codex-cli 0.148.0` 產生的 schema 完成離線測試；2026-08-20 已由實機 App 成功顯示「最新／Codex app-server」與真實使用比例，但測試套件不接觸真實帳號，也不保存原始 response。
- **其他版本或其他時間窗的跨界行為。** 2026-08-28 已完成一次 Claude session 離線跨窗觀察：舊百分比與舊 reset 一起保留，守門正確拒絕；目前仍只有單一樣本、單一 Claude Code 版本。
- **真正啟動 `claude` 子程序。** 執行器本身以系統內建指令實測，但沒有任何自動化測試會執行真實的 `claude`。
- ~~**設定視窗的分頁列。**~~ headless 擷取畫不出 `NSTabView` 的分頁列，但使用者已實際切換分頁操作過，**2026-08-26 以人工驗收結案**。
- **多個 Claude Code 視窗是否共用同一份 usage 快取。** 需要兩個並行視窗的人工比對，尚未執行。
- **別台 Mac 上的 Gatekeeper 行為。**
