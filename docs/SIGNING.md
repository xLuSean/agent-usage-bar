# 簽章設定

Agent Usage Bar 目前只有兩種刻意支援的發布模式：免費的 ad-hoc，以及未來可能採用的 Developer ID＋Apple 公證。Apple Development 不再是這個專案的打包模式。

| 目的 | 簽章 | 結果 |
|---|---|---|
| 本機建置、目前的免費 alpha DMG | ad-hoc（預設） | 不需要 Apple 帳號或憑證；從網路下載後需手動通過 Gatekeeper |
| 未來讓一般下載者正常雙擊開啟 | 明確指定 Developer ID Application，再送 Apple 公證 | 需要付費 Apple Developer Program |

## 目前預設：ad-hoc

共用 `Shared.xcconfig` 固定為 `Manual`、`CODE_SIGN_IDENTITY=-`、空 Team。它不 include 任何本機設定，因此 fresh clone、Xcode Release 與公共打包都不會偷偷讀到開發者機器上的 Team、identity 或其他 compiler settings。

只讀預覽：

```bash
./scripts/package_dmg.sh --preflight
./scripts/release.sh plan
```

正式候選由 `release.sh prepare` 授權低階打包器；腳本會固定使用 ad-hoc，不查詢或自動選擇這台 Mac 已安裝的憑證。這是目前刻意的發布政策，不是「找不到憑證才退回」的備援。

0.3.0 以前，穩定的 Apple Development identity 用來讓直接讀取 Claude Keychain credential 的宿主 App 延續「一律允許」。現在 App 不再讀 Keychain；它只啟動 Claude Code 的唯讀 `/usage`，登入由 CLI 自己處理。2026-08-26 的受控實機 smoke test 也確認：ad-hoc、無 Team、hardened runtime 的 Release build 可以取得 Claude 讀數。因此這個舊簽章理由已退場。

## 為什麼不使用 Apple Development

Apple Development 只能標示本機開發者身分，不能讓第三方 Mac 正常通過 Gatekeeper，也不能取代公證。對目前 App 而言，它沒有額外功能，卻會讓公開成品帶有可檢查的個人 signer／Team metadata。

打包腳本因此拒絕 Apple Development identity。專案也不再提供 `LocalSigning.xcconfig` 或範例檔；若本機只想執行與除錯，ad-hoc 已足夠。

## 未來的 Developer ID 模式

只有決定加入付費 Apple Developer Program 時才使用。完整流程需要：

1. 取得 **Developer ID Application** 憑證。
2. 保持 Hardened Runtime（專案已啟用）。
3. 明確把完整公開 identity 傳給打包腳本：

   ```bash
   SIGN_IDENTITY_OVERRIDE="Developer ID Application: Public Name (TEAMID)" \
     ./scripts/release.sh plan

   SIGN_IDENTITY_OVERRIDE="Developer ID Application: Public Name (TEAMID)" \
     ./scripts/release.sh prepare
   ```

4. 把 App／DMG 送 Apple 公證，並將結果 staple 回公開成品。
5. 驗證最終 signer、notarization、Gatekeeper、來源 commit 與 checksum。

只指定 Developer ID 但沒有公證，仍不是完整的第三方發布流程。plan 與 prepare 必須使用同一個明確 identity；candidate manifest 會讀回並記錄 signer。不得把未公證成品描述成已通過 Gatekeeper 的正式 release。

## 公開前檢查

- 共用 Xcode project 不含 Team ID、個人 identity、provisioning profile 或 entitlement 檔。
- 打包預設必須回報 `Signing: ad-hoc`。
- 非 ad-hoc 模式只接受完整的 `Developer ID Application:` identity；不得自動選擇機器憑證。
- 打包必須從指定 Git commit 的 tracked source export 建置，不能讀取 ignored／untracked build settings。
- 若維護者沒有付費帳號，README 必須照實說明 Gatekeeper 手動放行步驟。

## 目前決定

使用者已決定目前不申請付費帳號。因此公共 alpha 採 ad-hoc、未公證 DMG；待真的要改善第三方安裝體驗時，再把 Developer ID、公證與乾淨 Mac 驗收當成同一項工作處理。
