# Release automation design record

狀態：**歷史設計紀錄；工具已實作。** 目前版本、下一個候選與實際操作指令以 [`Version.xcconfig`](../macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig)、`./scripts/release.sh plan` 與 [PACKAGING.md](PACKAGING.md) 為準。

這份文件保存發布工具背後不應輕易改變的理由，不再重複維護「目前版本」、「下一版號」或「現在還在等哪項複核」。這些資訊會隨每次候選改變，放在設計文件裡容易再次與程式漂移。

## 為什麼需要 release transaction

早期多個不同 DMG 曾使用相同版本名稱，build 也會受 Git 歷史重建影響。新的流程把版本、完整驗證、版本 commit、打包、人工驗收與 tag 分開，確保每份候選都能追溯到唯一來源，且失敗不會被包裝成成功。

穩定目標是：

- App metadata、DMG 檔名、checksum、candidate manifest、來源 commit 與 tag 指向同一份內容。
- 每份可交付候選都有新的 marketing version 與單調增加的 build。
- 驗證與重建不消耗版本號；Git 歷史重建不會讓 build 倒退。
- 工具不覆蓋或自動丟棄既有成品，不自動 push、建立 GitHub Release、安裝 App 或接觸 provider credential。

## 版本規則

`Version.xcconfig` 是版本、build 與 pre-release suffix 的唯一 committed source。Xcode project 不另外保存重複值。

- 一般候選：patch 與 build 各加一。
- 明確跳下一個 minor：minor 加一，patch 從 `100` 開始；這只有維護者刻意選擇 `--next-minor` 時才發生。
- patch 到 `999` 時，一般遞增停止，要求重新選擇版本方向。
- build 是獨立的 committed counter，不從 commit 數推導；超過 Apple 相容政策前必須重新裁決，不自行換格式。
- alpha／beta／正式版 suffix 也是 committed metadata，不能用臨時環境變數把同一來源冒充成另一種成品。

工具最初用隔離 fixture 驗證過從舊 `0.3.2 (1)` 明確跳到 `0.4.100 (4100)` 的遷移。那是歷史測試案例，不是目前的 release 指令或下一版宣告。

## 三段流程

### Plan

只讀取並顯示當下 HEAD、tree、repo-local commit identity、目前與目標版本、架構、簽章、tag 與輸出名稱。它不寫檔、不建立 lock，也不執行 provider。

### Prepare

在單一 lock 下重新檢查乾淨 `main` 與輸出碰撞，更新唯一版本檔，執行完整 verifier，只提交該版本檔，再以一次性的 exact plan 授權低階 packager 從 committed source 建立 DMG、checksum 與 candidate manifest。

低階 `package_dmg.sh` 沒有 exact plan 時不能把完整候選寫入 `dist/`。建置前後都要確認來源沒有漂移，並讀回 built／mounted App 的 bundle id、版本、build、suffix、source commit、實際架構與 signer。

### Finalize

人工安裝並驗收 exact DMG 後，維護者指定 exact candidate manifest。工具重新驗證檔名、bytes、SHA-256、App metadata、Git 狀態與來源 commit，然後只建立本機 annotated tag；不 push，也不移動既有 tag。

## 失敗語意

- Plan 或 mutation 前失敗：不改檔案、commit、tag 或成品。
- 版本更新後、commit 前失敗：不 commit、不打包，保留精確版本差異供檢查。
- 版本 commit 後打包失敗：保留 commit，不 tag；該版本可視為已消耗，不重寫歷史。
- 人工驗收失敗：保留 candidate 證據，不 tag；修正後建立下一個版本。
- Transaction 狀態不明或同名輸出碰撞：停止並人工檢查，不重播、不覆蓋、不自動改名或清除。

## 不在工具權限內

- Push、建立 GitHub repository／Release 或上傳附件。
- Developer ID 購買、Apple 公證與 stapling。
- 安裝 App、讀取真實 Claude／Codex 用量或處理登入。
- 自動更新、universal binary 或清除歷史備份。

## 驗證責任

`./scripts/verify.sh` 在隔離 Git repository 測試版本政策、plan 只讀、prepare mutation scope、不可覆蓋、exact-source 打包與 finalize tag readback，並另外建置真正的 Debug／Release App。現行測試證據見 [VERIFICATION.md](VERIFICATION.md)；實際候選操作只看 [PACKAGING.md](PACKAGING.md)，不要從本歷史設計紀錄複製舊版號或舊指令。
