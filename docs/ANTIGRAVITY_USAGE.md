# Antigravity 的額度資料來源

App 如何取得 Antigravity 的方案額度：唯讀指令、JSON 結構、多模型群組映射、Free 方案處理與容錯策略。Claude 與 Codex 見 [CLAUDE_USAGE.md](CLAUDE_USAGE.md) 與 [CODEX_USAGE.md](CODEX_USAGE.md)；共用安全邊界與視覺語言見 [SAFETY.md](SAFETY.md) 與 [UI_SPEC.md](UI_SPEC.md)。

**App 自己不發任何 HTTP 請求，不碰憑證或本機資料庫，也不掃描本機 `language_server` 程序。** 數字完全來自官方 `agy` CLI 的固定唯讀指令。

## 1. 固定的唯讀指令

```bash
agy -p /usage --output-format json --print-timeout 15s
```

`AntigravityUsageCommand.arguments` 是常數，不經 shell，也沒有任何設定或上游回應能改寫它。執行時由 `AntigravityProcessRunner` 自動補上 `--log-file <isolated-cwd>/agy.log`，將 CLI 日誌導向每次查詢專屬的 `0700` 本機暫存目錄，子程序結束後整棵移除。

- **不消耗模型額度、不留下對話**：2026-11-22 以本機 `agy` 實測，即使在空白私人暫存目錄且 `stdin = /dev/null` 下執行，輸出均為 `status: "SUCCESS"`、`conversation_id: ""`、`num_turns: 0`、`duration_seconds: 0`，且所有 token 計數均為 `0`。
- **防禦模型回合誤讀**：解碼器明確要求 `command.name == "usage"` 且 `num_turns == 0`（若存在），絕不把任何一般模型回應誤當成額度資料。

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
- 單元測試與 AppKit self-test 涵蓋多群組解碼、Free 方案自動單槽、獨立 Toolbar／Popover 設定、fail-closed 邊界、失敗分類與靜態護欄（全部使用合成資料，不將真實帳號回應寫入 repo）。

**未驗證**

- `agy -p /usage --output-format json` 在實際斷網、帳號限流與完全未登入狀態下的確切 exit code 與錯誤文字（現行分類規則依據標準 Go/CLI 錯誤訊號設計，日後實測若有差異須補齊）。
- 不同作業系統帳號或 Free／Ultra 方案下的所有群組命名變化（解碼器以動態群組名稱處理，不寫死群組清單）。
