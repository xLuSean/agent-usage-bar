# Packaging and distribution

Agent Usage Bar 把「建立候選版」與「確認它可發布」分成兩段。工具不會安裝 App、不會 push、不會建立 GitHub Release，也不會自動選本機憑證。

## 版本只有一個來源

版本、build 與 pre-release suffix 都保存在：

```text
macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig
```

Xcode 的 Debug／Release、App 內 metadata、DMG 檔名、checksum、candidate manifest 與最後的 Git tag 都必須讀到同一組值。Build 是 committed counter，不再依賴 Git commit 數，因此重置或重建歷史不會讓 build 倒退。

目前 committed metadata 是 `0.4.103 (4103), alpha.1`。下一個一般候選由工具計算為 `0.4.104-alpha.1 (4104)`。這行只記錄 2026-08-28 的現況；真正執行時一律以 `Version.xcconfig` 與當下的只讀 plan 為準，不從文件猜版本。

`--next-minor` 只在維護者明確決定跳到下一個 minor 時使用。以目前版本執行會產生 `0.5.100`，因此它不是建立下一個候選的預設指令。

## 只讀檢查

低階 preflight：

```bash
./scripts/package_dmg.sh --preflight
```

它只確認 working tree 乾淨、committed metadata 合法、HEAD 存在，以及簽章政策有效，不建置、不寫檔。

完整 release plan：

```bash
./scripts/release.sh plan
```

plan 會顯示目前與目標版本、完整 commit／tree、repo-local commit identity、唯一預期 source 變更、架構、簽章模式、tag 與三個輸出名稱。它不建立 lock，也不改 HEAD、index、working tree 或 refs。

## 建立 candidate

維護者確認 plan 後，一般候選執行：

```bash
./scripts/release.sh prepare
```

Prepare 會依序：

1. 取得單一 release lock，重新確認 `main`、乾淨 working tree、沒有未完成 Git operation、輸出與 tag 不碰撞。
2. 原子更新 `Version.xcconfig`，執行完整 `./scripts/verify.sh`。
3. 確認 verifier 只留下精確版本差異，再建立只包含該檔的 `release: prepare ...` commit。
4. 讀回 parent、changed path、source commit／tree 與 committed metadata。
5. 建立一次性的本機 transaction plan，授權低階 packager 從該 exact commit 的 `git archive` 建置。
6. 讀回 built App 與唯讀掛載 DMG 內的 bundle id、版本、build、suffix、source commit、實際 CPU 架構及 signer。
7. 驗證 DMG，再以不可覆蓋方式發布 checksum、candidate manifest，最後才讓 DMG 出現在 `dist/`。

三個成品會互相指認：

```text
Agent-Usage-Bar-<release>-b<build>-<arch>.dmg
Agent-Usage-Bar-<release>-b<build>-<arch>.dmg.sha256
Agent-Usage-Bar-<release>-b<build>-<arch>.dmg.candidate.json
```

Candidate manifest 只記錄發布證據，例如版本、build、來源 commit／tree、架構、bundle id、basename、bytes、SHA-256、簽章讀回與尚未公證；不保存本機絕對路徑、credential、provider response、session 或帳號資料。

完整打包不能直接執行 `package_dmg.sh`。低階 packager 只接受 `release.sh prepare` 建立的 exact one-shot plan；plan 在 build 前由 `prepared` 改為 `executing`，中斷後不會自動 replay。這是為了避免「工具其實已經做完一半，重跑又做第二次」的未知結果。

## 人工驗收與 finalize

Candidate 不是正式 release。請安裝 manifest 指定的同一份 DMG，至少確認：

- App 顯示 manifest 的版本與 build。
- Claude、Codex 真實資料符合當下核准的機制。
- 設定、中英文、選單列與基本互動沒有漂移。
- 驗收 DMG 的 SHA-256 等於 manifest。

通過後，指定 exact manifest 建立本機 annotated tag：

```bash
./scripts/release.sh finalize dist/<exact-candidate-manifest>.json
```

Finalize 不會猜「最新」檔案，也不接受 `dist/` 以外的 manifest。它會重算 bytes／SHA-256、唯讀掛載 DMG、讀回 metadata／架構／signer，並要求目前仍是乾淨 `main` 且 HEAD 等於 candidate source commit。第一次建立 tag 前，它還會讀回 prepare 留在 `tmp/release-transactions/<source-commit>.json` 的 `packaged` 紀錄，比對 exact manifest 名稱、DMG bytes／SHA-256 與 manifest SHA-256；這能擋下拿錯檔、部分替換或交易紀錄與候選不一致。

Finalize 成功後，exact annotated tag 會保存 source commit／tree、DMG 名稱、bytes 與 SHA-256。日後即使已清理 ignored `tmp/`，同一份仍通過完整 candidate 驗證的 manifest／DMG，只要 tag 型別、指向與 annotation 全部吻合，就會安全回報「已完成、沒有變更」；不會因暫存 transaction 消失而破壞冪等 readback。若 tag 任一欄不同，仍立即停止且絕不移動既有 tag。

這筆本機交易紀錄是防誤用與稽核證據，**不是密碼學上的發布者身分**：同一個已能任意改寫 repository 與 `tmp/` 的本機使用者，也能改寫它。真正的對外發布者驗證仍需要 Developer ID／公證、維護者控制的外部簽章，或另一個可信通道保存 digest。Finalize 成功後只建立本機 tag，仍不 push 或發布遠端 Release；既有 tag 永遠不會被移動。

## 失敗時會留下什麼

- 版本驗證失敗：不 commit、不打包、不 tag；保留版本差異供人檢查。
- 版本 commit 成功但打包失敗：commit 保留，沒有 tag；該版本視為已消耗，不重寫歷史。
- Candidate 驗收失敗：DMG、checksum、manifest 保留作診斷，不 tag。
- `executing` transaction：代表結果未知，先檢查 `dist/` 與本機 transaction record，不直接重跑。
- 任何同名 DMG、checksum、manifest 或 tag：立即停止；不覆蓋、不改名、不移到垃圾桶，也不猜下一版。

## 簽章

預設為 ad-hoc，不需要 Apple 帳號或憑證：

```bash
./scripts/release.sh plan
./scripts/release.sh prepare
```

若日後加入付費 Developer ID，只能在 plan 與 prepare 明確提供同一個完整 identity：

```bash
SIGN_IDENTITY_OVERRIDE="Developer ID Application: Public Name (TEAMID)" \
  ./scripts/release.sh plan

SIGN_IDENTITY_OVERRIDE="Developer ID Application: Public Name (TEAMID)" \
  ./scripts/release.sh prepare
```

Apple Development identity 會被拒絕。完整理由見 [SIGNING.md](SIGNING.md)。

## 校驗

Checksum 可獨立確認：

```bash
cd dist
shasum -a 256 -c Agent-Usage-Bar-<release>-b<build>-<arch>.dmg.sha256
```

Checksum 只能證明檔案位元組相同；它不能證明發布者身分，也不能取代 Developer ID 與 Apple 公證。

## 尚未完成的公開發布工作

- **未經 Apple 公證。** 目前 ad-hoc 成品從網路下載後需要手動通過 Gatekeeper。
- **未做乾淨第三方 Mac 驗收。** 本機 build 或直接複製不會重現瀏覽器下載的 quarantine 體驗。
- **沒有自動更新機制。**
- **只建置指定的單一 CPU 架構。** 沒有 universal binary。
- **工具不處理 GitHub。** Push tag、建立 Release 與上傳三個附件要另行明確執行。

## App 圖示

圖示由 App 自己繪製並 commit 在 `Resources/AppIcon.icns`。它不在 release 流程裡，因為畫圖需要先有可執行 App；只有設計改變時才重新產生。
