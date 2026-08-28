# Claude 的額度資料來源

App 如何取得 Claude 的方案額度：欄位、格式與容錯策略。Codex 那一側見 [CODEX_USAGE.md](CODEX_USAGE.md)；兩者共用的邊界與視覺語言見 [SAFETY.md](SAFETY.md) 與 [UI_SPEC.md](UI_SPEC.md)。

**App 自己不發任何 HTTP 請求。** 數字來自官方 CLI 的一個固定唯讀指令。

舊的「鑰匙圈 ＋ 未文件化 OAuth endpoint」原型已於 0.3.0 完整退場，公開版本沒有該路徑也沒有自動 fallback。當初那條路怎麼做的、踩到什麼、以及什麼情況下值得走回去，記在 [LEGACY_KEYCHAIN_PATH.md](LEGACY_KEYCHAIN_PATH.md)。

## 1. Claude：一個固定的唯讀指令

```bash
claude --safe-mode --no-session-persistence -p "/usage" --output-format json
```

參數是常數（`ClaudeUsageCommand.arguments`），沒有設定介面餵它，也沒有任何回應能影響它。不經 shell，直接以 `Process.executableURL` 執行驗證過的一般檔案。

## 2. 兩層結構，只有一層是契約

外層是真正的 JSON，欄位穩定：

| 欄位 | 用途 |
|---|---|
| `is_error` | 必須是 `false`。**缺這個欄位視同錯誤** —— 沒有成功訊號不等於成功 |
| `subtype` | 必須是 `"success"` |
| `result` | 人類可讀的文字，額度數字在裡面 |

內層 `result` 是為人閱讀的英文散文，**沒有欄位 schema**：

下列數字與時間只示範格式，不是任何真實帳號的讀數：

```text
Current session: 40% used · resets Jan 15 at 1am (Etc/UTC)
Current week (all models): 10% used · resets Jan 19 at 12pm (Etc/UTC)
```

**`Current session` 的 reset 子句是選用的。** 沒有進行中的時間窗時，它只印百分比：

```text
Current session: 0% used
```

原因是**五小時窗從「上一段結束後第一次使用」起算，不是照時鐘對齊**。實機曾觀察到相鄰重置略超過五小時；中間那段沒有窗，也就沒有 reset 可報。

`Current week (all models)` 的 reset **仍為必要** —— 週窗永遠在跑，它少了 reset 才是真的格式漂移。這個不對稱是刻意的。

兩行都必須出現且各只能出現一次。分隔符號是 `·`（U+00B7）。

## 3. 只有那兩行進入計算

`result` 後半還有一段本機活動統計 —— 請求數、session 數、用了哪些 skill 與 MCP server 及其占比。那是**使用者的私人工作紀錄**，而且與百分比不同來源（前者由本機 session log 算出，後者來自伺服器的限額資料）。

它**不被解析、不被保存、不被顯示，也不會出現在任何錯誤訊息裡**。外層那個一次性的 `session_id` 同樣不保存。

外層的 `usage` 物件描述的是這次 CLI 呼叫本身的 token 數（全部為 0），**不是方案額度**，不可誤用。

## 4. 重置時間的格式

實測至少兩種形式，解析器必須都接受：

| 形式 | 例子 |
|---|---|
| 含分鐘 | `Jan 15 at 12:59am (Etc/UTC)`（合成示例） |
| 整點省略分鐘 | `Jan 15 at 1am (Etc/UTC)`、`Jan 19 at 12pm (Etc/UTC)`（合成示例） |

三個容易寫錯的地方：

- **12 小時制的 12。** `12am` 是午夜（0 時），`12pm` 是中午（12 時）。天真的「pm 就 +12」兩個都會錯。
- **沒有年份。** 年份由「離現在最近」推出來，否則 12/31 的重置在 1/1 讀到會跳回十一個月前。
- **時區是文字裡指定的**，不是本機時區。用本機時區解讀會讓機器與帳號時區不一致的人每個重置時間都偏掉。未知 IANA timezone 會直接 fail closed，不會退回呼叫端或本機時區猜測。

## 5. 容錯策略：fail closed

與舊路徑相反。舊的 JSON 端點對壞掉的陣列元素逐一跳過，因為欄位多、缺一個不影響其他。這裡只有兩行，**任何一行對不上就整份失敗**：

| 情況 | 結果 |
|---|---|
| 缺任一行 | `schemaChanged` |
| 同一個窗出現兩行 | `schemaChanged` —— 選哪個都是在賭使用者看到的數字 |
| 百分比 > 100 | `schemaChanged` —— 不 clamp，clamp 會把誤讀變成一個有自信的 100% |
| 重置時間無法解析 | `schemaChanged` |
| 非 JSON、`is_error`、非 success subtype、空 `result` | 對應的錯誤 |

**不猜、不補 0%、不沿用舊值。** 顯示「未知」的代價是使用者多看一眼；顯示錯的數字的代價是他照著那個數字做的決定。

## 6. 和 Claude Code 自己的畫面對不上時，多半是那邊比較舊

一次同機、近同時觀察中，本 App 與直接執行 `/usage` 的數字彼此接近；Claude Code 狀態面板的 session 與同一週窗內的 weekly 數字都明顯較舊。這裡只保留相對結論，不公開真實帳號的百分比與取得時間。

**Claude Code 內部不同介面的 usage 資料不是同步的。** 狀態面板會停在某個時間點的快照，`/usage` 則是每次執行時重新取得。本 App 用的是後者。

所以兩邊數字不同時，先看週用量哪一個比較大 —— 大的那個比較新。

## 7. 新鮮度守門

`/usage` 連不上伺服器時會安靜地退回 Claude Code 的本機快取，而文字裡沒有「這筆數字是幾點拿到的」。2026-08-28 的一次離線跨窗觀察直接看到上一個窗的百分比與 reset 原封不動回傳；恢復 Wi-Fi 後才取得新窗資料。指令耗時不能用來判斷是否連網，因為離線與連網樣本的時間互相重疊。

守門設計上應使用每個必要時間窗的重置時間推出上限：

- 重置時間 + 60 秒寬限 **還沒到** ⇒ 快取寫在當前窗內 ⇒ 最舊不超過一個窗。
- 重置時間**已經過了** ⇒ 這筆讀數描述一個結束了的窗 ⇒ `claudeUsageOutdated`，顯示不可用。

寬限吸收時鐘誤差，以及「真實邊界 00:59:59 vs 文字寫 1am」這一秒。

session 與 weekly 兩個必要時間窗都逐一檢查；任何一個 reset 已跨界，整份讀數都不可用。守門仍擋不到窗內的落後，因此 session 最壞可接近 5 小時舊。

## 8. 守門的關鍵假設：一次離線跨窗觀察

守門要成立，得排除兩種機制完全不同的失效方式：

- **(A) 重置時間自己往前跑** —— 值若是相對的、每次重算，舊快取也會長出新的重置時間。
- **(B) 窗滾動時被改寫** —— 寫入新的重置時間，卻沿用舊的百分比。

**(A) 已排除。** 一次性檢視 Claude Code 記錄的 rate-limit 資料：

```text
rateLimitType: 'five_hour'
resetsAt:      <absolute Unix timestamp>
```

是絕對 Unix 時間戳，不是可重算的相對值。寫死的整數不會自己前進，所以放著不動的舊快取必然帶著舊的重置時間。該整數也與同期 `/usage` 文字顯示的重置時刻吻合。

**(B) 在一次離線跨窗觀察中沒有發生。** 測試機只有 Wi-Fi；關閉 Wi-Fi、跨過 reset 並等過 60 秒寬限後，仍收到上一個窗的非零百分比與舊 reset。兩個舊欄位一起保留，App 會正確判定過期。恢復 Wi-Fi 後再次查詢，才改為 `Current session: 0% used`，且沒有 reset 子句。

腳本把仍留在路由表裡的預設路線誤判成 `net=online`；那不是實際連線證據。測試機沒有其他網路介面，Wi-Fi 當時確實關閉。日後不得用路由項目或 `duration_ms` 代替真正的連線狀態。

**守門本身不會被繞過，這一條由 source 保證。** weekly 那行的重置時間在解析器裡是必要的，session 那行才是選用，所以每份被接受的讀數至少帶一個 `resetsAt` 進入檢查。但 weekly 的重置一週才動一次 —— 一份「新 session 重置 + 舊百分比」的讀數，仍可能從還有好幾天才到期的 weekly 重置底下通過。

這次結果支持現行守門，但證據範圍只有**單一樣本、單一 CLI 版本**。正確說法是「這次沒有發生 (B)」，不是「Claude Code 永遠不會發生 (B)」。

> 這次檢視是一次性診斷。App **不讀** Claude Code 的內部檔案，也不以它為備援。

## 9. 失敗分類

非零 exit 時讀 stderr 與 stdout 前綴**只為了分類**，內容不進 UI、不進 log、不進錯誤訊息。

| 訊號 | 錯誤 | 提供的指令 |
|---|---|---|
| `unknown option`、`unrecognized option` 等 | `claudeVersionUnsupported` | 無（要更新，形式依安裝方式而異） |
| `not logged in`、`please sign in` 等 | `claudeNotSignedIn` | `claude` |
| 其他 | `claudeCommandFailed`（只帶 exit code） | 無 |
| 逾時 30 秒 | `claudeCommandTimedOut` | 無 |
| 找不到／不可執行 | `claudeExecutableNotFound`／`Invalid` | 無（要安裝或指定路徑） |

版本訊號優先於登入訊號：舊版拒絕 `--safe-mode` 時常會連帶印出提到登入的說明文字，而「更新 Claude Code」才是真正有用的那一步。

## 10. 已驗證 vs 未驗證

**已驗證（2026-08-24，Claude Code 2.1.231）**

- 指令成功回傳，`is_error=false`、`num_turns=0`、所有 token 計數 0、`total_cost_usd=0`。
- 兩種重置時間格式都實際出現過。
- 斷網仍回傳數字；指令耗時不能區分離線與連網。
- 2026-08-28 離線跨窗時，舊百分比與舊 reset 一起保留，守門正確拒絕；恢復 Wi-Fi 後取得 `0%`、無 reset 的新窗輸出。
- CLI 與退役端點在近時間讀取時落在合理變化範圍內，重置時間一致。

- Claude Code 的狀態面板與 `/usage` 可能給出不同數字；本 App 用的 `/usage` 是較新的那一個（§6）。

**未驗證**

- 文字格式的長期穩定性。沒有公開 schema，隨時可能改。
- 是否會依系統語言在地化。子程序的 `LANG`／`LC_ALL` 已固定為英文，但解析器不依賴它。
- 其他 Claude Code 版本或其他時間窗的跨窗行為；目前只有一次直接觀察。
- `/usage` 是否反映不經過 Claude Code 的用量，例如 Claude Desktop 或 claude.ai。
- 支援 `/usage` 的最低 Claude Code 版本。不硬編，以執行結果判定。

## 11. 視窗身分的映射

`/usage` 稱短期限制為 `Current session`，文字裡沒有「5 hours」。App 沿用既有的 5 小時標籤（`UsageWindow.Kind.session`）以維持 UI 一致，但那是一個**映射，不是它自己說的**。`Current week (all models)` 對到 `weeklyAll`。

文字也沒有說哪一個限制是**目前綁定**的，所以 `isActive` 一律為 `false` —— 從百分比高低猜會把「目前綁定」的標記貼在一個推論上。
