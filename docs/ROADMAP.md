# Roadmap

## 已完成

**產品與 UI**：Claude／Codex 雙量表、合併選單列圖示、popover 詳情、目前 Space 的設定視窗、內容超出螢幕時才捲動、中英文切換、登入時啟動與原創圖示均已完成並經使用者確認。視覺與互動契約見 [UI_SPEC.md](UI_SPEC.md)。

**唯讀 providers**：Claude 只執行固定、shell-free 的 `/usage` CLI 查詢；Codex 只使用官方 App Server 的 rate-limit read 與更新通知。兩者各自設定、退避、保存最新讀數，任何一邊失敗不拖累另一邊。資料來源與格式漂移分別見 [CLAUDE_USAGE.md](CLAUDE_USAGE.md) 與 [CODEX_USAGE.md](CODEX_USAGE.md)，共用的安全邊界見 [SAFETY.md](SAFETY.md)。

**可靠性與安全修正**：Codex sparse push 與逾時復原、設定切換隔離、Claude 時間窗 fail-closed、兩個 provider 的子程序 hard bound、Codex 數字 fail-closed、外部錯誤文字清理、未來時間戳自我修復、多原因輪詢暫停，以及取消排程與 UI 一致性均已完成。現行測試範圍見 [VERIFICATION.md](VERIFICATION.md)。

**保守瘦身**：Release 已排除測試 fixture；無消費者的輪詢模型、HTTP backoff 遺留欄位、provider 假契約、snapshot 診斷 metadata、上游 severity 與無可靠來源的 Extra Usage surface 均已移除。真正使用中的 `RefreshInterval`、`FetchPacing`、`RetryBackoff`、Codex push identity 與舊 snapshot 相容性保留，verifier 有永久護欄防止退役 surface 回歸。

**建置與發布準備**：Debug／Release Xcode builds、隔離 AppKit diagnostics、雙語 render、read-only GitHub Actions，以及有單一 committed 版本來源的本機 release transaction 均已完成。候選 DMG 必須由 exact plan 建立，不覆蓋既有成品，並同時產生 checksum 與 candidate manifest；tag 只在人工驗收後建立。本機歷史 DMG 不是公開 release；正式證據與發布限制見 [VERIFICATION.md](VERIFICATION.md) 與 [PACKAGING.md](PACKAGING.md)。

## 下一步（依價值排序）

1. **建立與目前 source 一致的新候選。** 每次公開收尾若改到 shipping code，都應重新從 `./scripts/release.sh plan` 建立下一個一般候選，不可把舊 DMG 當成新 source 的證據。版本與 build 只讀取 committed metadata；release 工具不執行 reset 或 history rewrite。
2. **網路恢復偵測。** 斷網後恢復連線時重新整理，不必等下一次排程。
3. **乾淨 Mac 驗收、自動更新與 universal binary。** 依實際公開需求分階段處理。

## 待決

- **第三方機器上的安裝流程未經驗證。** 建置機器上的 `spctl` 已回報 `rejected`，README 寫出預期的系統設定放行步驟，但**沒有人在別台 Mac 上走過一次**。公開發布前應使用另一台 Mac（或至少一個從未核准過此 App 的乾淨使用者環境），從瀏覽器下載實際待發布的 DMG；直接複製本機 build、用隨身碟傳檔或從建置目錄啟動不能代表真實下載流程，因為檔案可能沒有 macOS 的 quarantine「來自網路」標記。

  驗收時依序確認：下載的 DMG 帶有 quarantine 標記 → 拖入 `/Applications` → 一般雙擊確實觸發預期的 Gatekeeper 阻擋 → 只按照 README 提供的步驟即可放行 → 第二次啟動不再重複阻擋 → App UI 正常。若該機器另外已安裝並登入 Claude Code／Codex，再確認兩個 provider 能更新；provider 測試不得記錄 raw response、session id、活動明細或 credential。測試要記錄 macOS 版本、CPU 架構、實際提示文字及成功步驟，任何一步與 README 不符都算驗收失敗並先修文件或包裝。

- **是否追求 Mac App Store。** 需先完成 sandbox 可行性評估。Claude provider 單獨可沙盒化。目前傾向不做 —— App Store 需要付費帳號，而使用者已決定不申請。

## 擱置

- **用真實回應建 fixture。** 原本排在前面，2026-08-20 決定先擱著。真實 payload 的解析已經實機驗證過了，所以這件事剩下的價值只有「日後改動時的回歸保護」—— 中等偏低。而且 App 刻意不記錄完整回應（[SAFETY.md](SAFETY.md) §2），要做得先開一個匯出功能，等於為了一份測試資料在安全邊界上開口。等哪天解碼器真的出問題、需要用真實資料重現時再說。

## 不做

這些是**已決定的非目標**，不是還沒做：

- 不儲存歷史取樣、不繪製時間序列、不做用量預測。
- 不顯示精確剩餘 token 數 —— 端點提供的是百分比與時間窗，不是固定上限。
- 不實作 OAuth 登入或 refresh 流程。
- 不恢復舊的 Keychain／HTTP provider、混合 User-Agent spike 或 `POST /v1/messages` fallback；任何重新引入直接 credential access 的提案都必須重新做安全設計並由維護者明確裁決。
- 不跨機同步、不多帳號切換。
- 不使用任何官方標誌。
