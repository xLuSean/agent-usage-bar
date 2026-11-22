# Antigravity 的額度資料來源

App 如何取得 Antigravity 的方案額度：唯讀指令、JSON 結構、多模型群組映射、Free 方案處理與容錯策略。Claude 與 Codex 見 [CLAUDE_USAGE.md](CLAUDE_USAGE.md) 與 [CODEX_USAGE.md](CODEX_USAGE.md)；共用安全邊界與視覺語言見 [SAFETY.md](SAFETY.md) 與 [UI_SPEC.md](UI_SPEC.md)。

**App 自己不發任何 HTTP 請求，不碰憑證或本機資料庫，也不掃描本機 `language_server` 程序。** 數字完全來自官方 `agy` CLI 的固定唯讀指令。

## 1. 固定的唯讀指令

```bash
agy -p /usage --output-format json --print-timeout 15s
```

`AntigravityUsageCommand.arguments` 是常數，不經 shell，也沒有任何設定或上游回應能改寫它。執行時由 `AntigravityProcessRunner` 自動補上 `--log-file <workspace>/agy.log`。`<workspace>` 是 App 暫存區裡一個固定名稱的 `0700` 本機目錄（`antigravity-workspace`），每次查詢前清空重建、子程序結束後整棵移除；日誌含帳號 email，所以不能留下。

- **不消耗模型額度、不留下對話**：2026-11-22 以本機 `agy` 實測，即使在空白私人暫存目錄且 `stdin = /dev/null` 下執行，輸出均為 `status: "SUCCESS"`、`conversation_id: ""`、`num_turns: 0`、`duration_seconds: 0`，且所有 token 計數均為 `0`。
- **防禦模型回合誤讀**：解碼器明確要求 `command.name == "usage"` 且 `num_turns == 0`（若存在），絕不把任何一般模型回應誤當成額度資料。
- **工作目錄路徑固定**：`agy` 會依工作目錄的路徑，在 `~/.gemini/antigravity-cli/implicit/` 留下一個約 460 bytes 的狀態檔，從不自行刪除。2026-11-22 以 `agy` 1.5.14 實測，每次換新路徑就多一個（照預設 10 分鐘頻率約每天 144 個）；同一路徑隔數分鐘重複執行則不再新增。那個位置不屬於本 App，所以改用固定路徑，而不是事後去清。兩份 App（例如驗證用的 bundle）共用同一個暫存根目錄，因此查詢期間持有同一資料夾內的檔案鎖，拿不到就短暫重試，再以可重試的失敗結束。
- **關閉背景自動更新**：子程序環境帶 `AGY_CLI_DISABLE_AUTO_UPDATE=true`（值必須是 `true`，`1` 無效）。不帶時，`agy` 只要距上次檢查超過 15 分鐘，就會在背景啟動自我更新程序；帶上後日誌記錄 "Auto-update disabled via environment variable"，也不再產生子程序。這個變數與上一條的路徑行為都不在官方文件裡，是從 `agy` 1.5.14 實測得知。
- **已知限制：會啟動使用者的 MCP 伺服器**：`agy` 沒有類似 Claude Code `--safe-mode` 的開關，官方文件也未說明 print mode 是否載入 MCP。實測在 MCP 設定放一個只會等待的假伺服器，執行 `/usage` 時它就被啟動，`agy` 結束後仍在執行；它沒有佔住 App 讀取的輸出管道，所以不會拖慢查詢。外掛自帶的 MCP 在實測日誌中因登入尚未就緒而略過，這是啟動時的先後順序，不保證每次如此。本 App 不改寫使用者的 `agy` 設定，因此沒有隔離這一點。

## 2. 結構化 JSON 與欄位規則

App 只讀取外層成功訊號與 `command.data.groups[]`：

| 欄位 | App 的處理 |
|---|---|
| `status` | 必須為 `"SUCCESS"`，否則視為指令失敗 |
| `num_turns` | 若提供必須為整數 `0`，否則 fail closed 回 `schemaChanged` |
| `command.name` | 必須為 `"usage"` |
| `command.data.groups[]` | 最多取前 16 個群組、總計最多 32 個額度桶；保留上游群組順序 |
| `groups[].name` | 經 `ProviderMetadataText.normalizedDisplay` 驗證（最多 512 UTF-8 bytes、拒絕控制字元與方向格式字元） |
| `buckets[].window` | `"5h"` → `sessionScoped`（300 分鐘）；`"weekly"`／`"7d"` → `weeklyScoped`（10,080 分鐘）；其餘安全識別字保留為 `unrecognized` |
| `buckets[].remaining_fraction` | 必須是有限非布林數字且介於 `0.0...1.0`，換算為已用百分比 |
| `buckets[].reset_time` | ISO 8601 時間字串（接受含或不含小數秒），套用 `+60s` 過期守門 |

### 2.1 `remaining_fraction` 換算與耗盡邊界

Antigravity 回報的是剩餘比例 `remaining_fraction`（`0...1`），本 App 統一轉換為已用比例以維持跨供應商一致的視覺刻度（[UI_SPEC.md](UI_SPEC.md) §1、§3）：

- `remaining_fraction == 0.0` → `100%` 已用（已耗盡）。
- 極小正數（例如 `0.002`）若直接四捨五入會變成 `100%` 並誤判為已耗盡，因此當 `remaining_fraction > 0` 但四捨五入達 `100` 時，上限固定為 `99%` 已用（`1%` 剩餘）。
- 範圍外、非有限值、布林值或非數字一律 fail closed 回報 `schemaChanged`。

### 2.2 多模型群組與 Free 方案

Antigravity 依模型群組分池（例如 `Gemini Models`、`Claude and GPT models`、`Gemini 4 Argon`），沒有單一「全部模型共用」總池：

- **選單列（Toolbar）**：預設追蹤 `Gemini Models`，設定頁可獨立切換為其他群組或「最高用量群組（5h 與 7d 各自取已用比例最高者）」，並可與詳情面板分開選擇要顯示 `5 小時與 7 天`、`僅 5 小時` 或 `僅 7 天`。
- **Free 方案／純週額度群組**：當所選群組僅有 `weekly` 額度、沒有 `5h` bucket（例如 Free 方案或 `Gemini 4 Argon`），即使選單列設定為「5 小時與 7 天」，選單列仍自動收斂為**單槽 7 天量表**（20 × 18 pt），詳情面板也直接省略不存在的 5 小時列，不以 `0%` 或空白列佔位。
- **詳情面板（Popover）**：預設顯示所有模型群組的完整額度（`Gemini Models` 預設展開，其餘群組預設收合為一行且仍保留 `% used`，可個別點開並記住收放狀態），並可在設定頁獨立選擇顯示所有群組或特定群組，以及獨立選擇顯示 `5 小時與 7 天`、`僅 5 小時` 或 `僅 7 天`。

## 3. 失敗分類與安全邊界

非零 exit 時只讀截斷後的 stderr／stdout 前綴來分類失敗，原文不進 UI、不進錯誤訊息、也不進診斷紀錄：

- 參數不被接受（`unknown flag`、`flag provided but not defined` 等）→ `antigravityVersionUnsupported`
- 未登入訊號（`not logged in`、`unauthenticated`、`unauthorized` 等）→ `antigravityNotSignedIn`（提供複製 `agy`，不代為執行登入）
- 網路錯誤（`no such host`、`network is unreachable`、`dial tcp` 等）→ `offline`
- 其他非零 exit → `antigravityCommandFailed`（僅帶 exit code）
- 逾時 30 秒 → `antigravityCommandTimedOut`（先 `SIGTERM`，1 秒 grace 後僅對 exact owned child 送 `SIGKILL` 並關閉 pipe read ends）

`verify.sh` 有四道靜態護欄：只有 `AntigravityUsageCommand.swift` 可以建構 `Process`、固定 arguments 逐字比對、`Antigravity/` 不得出現非唯讀子命令（`login`／`mcp`／`plugin`／`update`／`install`／`remote-control`／`--dangerously-skip-permissions` 等）或 shell。

## 4. 已驗證 vs 未驗證

**已驗證（2026-11-22）**

- 本機 `agy -p /usage --output-format json --print-timeout 15s --log-file <temp>/agy.log` 在隔離空白 `0700` 工作目錄與 `stdin = /dev/null` 下 exit 0，回傳 `status: "SUCCESS"`、`conversation_id: ""`、`num_turns: 0`、全零 token 計數，以及含多模型群組與 `remaining_fraction`／`reset_time` 的結構化 `command.data.groups`。
- 實測確認相鄰兩次查詢的 `remaining_fraction` 隨實際使用即時更新。
- 經由 App 的 Swift 執行器對真實 `agy` 1.5.14 查詢：固定路徑首次使用時 `implicit/` 多一個檔案，緊接著再查一次不增加。之後另一個路徑先查詢過一次（多出它自己的一個檔案），再回到固定路徑查詢，仍不增加。結論是每個路徑只留一個，不是「換過路徑就再留一個」。每次結束後工作目錄都已移除。
- 帶 `AGY_CLI_DISABLE_AUTO_UPDATE=true` 時，`agy` 日誌記錄自動更新已停用，且沒有任何子程序；不帶時（全新資料夾）會啟動背景更新程序。經由 App 的 Swift 執行器在距上次更新檢查超過 15 分鐘時查詢，`agy` 的更新檢查時間戳沒有變動。
- 在 MCP 設定放一個只會等待的假伺服器，`/usage` 會啟動它，`agy` 結束後它仍在執行，但輸出管道照常在約 2 秒內關閉。
- 單元測試與 AppKit self-test 涵蓋多群組解碼、Free 方案自動單槽、獨立 Toolbar／Popover 設定、fail-closed 邊界、失敗分類與靜態護欄（全部使用合成資料，不將真實帳號回應寫入 repo）。

**未驗證**

- `agy -p /usage --output-format json` 在實際斷網、帳號限流與完全未登入狀態下的確切 exit code 與錯誤文字（現行分類規則依據標準 Go/CLI 錯誤訊號設計，日後實測若有差異須補齊）。
- 不同作業系統帳號或 Free／Ultra 方案下的所有群組命名變化（解碼器以動態群組名稱處理，不寫死群組清單）。
- 其他 `agy` 版本是否仍依工作目錄路徑保存狀態、是否仍認得 `AGY_CLI_DISABLE_AUTO_UPDATE`。兩者都不在官方文件裡；若改變，App 不會報錯，只會讓留檔或背景更新重新出現。
- 外掛自帶的 MCP 伺服器在登入已就緒時是否也會被啟動；實測日誌只看到它們因登入尚未就緒而略過。
- 正式安裝的 App 在背景輪詢時的實際效果：這輪只在開發環境驗證，安裝新版前，舊版 App 仍會每次查詢多留一個檔案。
