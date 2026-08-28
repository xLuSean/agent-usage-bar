# 做過但行不通的事

這份文件只記**推翻過的決定**與**踩過的坑**。它存在的理由很單純：這些是唯一能阻止有人（包括未來的我們）把已經否決的做法再做一遍的東西 —— 而它們正好是看起來最像可以刪掉的內容。

被放棄的那條大路 —— 鑰匙圈加未文件化端點 —— 另外記在 [LEGACY_KEYCHAIN_PATH.md](LEGACY_KEYCHAIN_PATH.md)，因為它值得整份的篇幅。

> **目前的規格與現況不在這裡**，請看：
> [ARCHITECTURE](ARCHITECTURE.md) · [SAFETY](SAFETY.md) · [UI_SPEC](UI_SPEC.md) ·
> [CLAUDE_USAGE](CLAUDE_USAGE.md) · [CODEX_USAGE](CODEX_USAGE.md) ·
> [VERIFICATION](VERIFICATION.md) · [PACKAGING](PACKAGING.md) · [ROADMAP](ROADMAP.md)

## 起點（2026-08-18～19）

專案從三份計劃書開始：Claude 端方案、Codex 端方案，以及一份對照表。**那三份已經從 repo 移除** ——
它們描述的是已退場的鑰匙圈設計，還活著的結論都已經進到程式碼與其餘文件裡。

第一版實作刻意停在「客戶端識別」這個閘門前 —— 計劃書明訂那是使用者的價值判斷，實作不得代決。

閘門不是靠註解維持的，而是型別本身沒有預設值：`ClientIdentity`（現已隨舊路徑刪除）沒有 `.default`，
provider 的欄位是 `Optional` 且預設 `nil`，`fetch()` 在 `nil` 時**先於讀鑰匙圈**就拋錯。
使用者裁決選項 A 之後才接上 live 路徑。

## 推翻過的決定

計劃寫下的東西不是全都禁得起實作。以下三條是實作後被推翻的，理由記在各自的文件裡：

| 原本 | 改成 | 理由 |
|---|---|---|
| 每次查詢重讀鑰匙圈、不快取 | 快取到接近到期 | 每次讀取都可能跳授權對話框，而 token 自帶到期時間 —— 重讀什麼也沒買到（見 [LEGACY_KEYCHAIN_PATH](LEGACY_KEYCHAIN_PATH.md)） |
| 顏色優先採用回應的 `severity` | 只看百分比 | Codex 會有自己的判定標準，各聽各的會讓同一個顏色代表不同的事（[UI_SPEC](UI_SPEC.md) §3.1） |
| 量表填色代表剩餘 | 代表已用 | 兩家都以「已用」回報，中間多轉一次是混淆的來源 |

## 踩過的坑

**`swift build` 看不到 App 層。** 重構成 Xcode target 之後，App 層不再是 package target。
一個 SwiftUI 型別錯誤因此 `swift build` 通過、`xcodebuild` 才抓到。驗證必須跑後者。

**`MainActor.assumeIsolated` 是斷言不是切換。** 用在非主執行緒的憑證讀取路徑上，
造成一次進到已建置成品的當機 —— 跳密碼框、使用者輸入、App 當場終止，
看起來完全像鑰匙圈的問題。詳見 [VERIFICATION](VERIFICATION.md)。

**`NSStatusItem` 沒有 `autosaveName` 會互相蓋掉。** AppKit 會從 App 名稱推導一個，
兩個項目共用同一筆位置記錄，其中一個不會出現。

**瀏海不是可以繞過去的障礙物。** 狀態列圖示只能待在瀏海右邊的區域，
左邊屬於當下 App 的選單。空間不足時 macOS 直接不顯示，**不會通知 App**。
只能靠比對按鈕視窗座標與 `auxiliaryTopRightArea` 才察覺得到。

**ad-hoc 簽章的身分每次重建都會變。** 舊 Keychain provider 由宿主 App
直接讀 credential，所以每裝一版都可能被當成陌生 App；當時曾改成自動偵測
機器上的憑證。0.3.0 改由 Claude CLI 自己處理登入後，宿主簽章不再參與
credential access，打包也回到 deterministic ad-hoc；真正的第三方發布只接受
日後明確指定的 Developer ID，而不是自動選 Apple Development。

**授權對話框的預設按鈕是最寬鬆的那個。** 輸入密碼後按 Enter 送出的是「允許」
（只放行一次），不是「一律允許」。

## 事故

開發期間一次 credential 調查誤把秘密內容輸出到診斷畫面。這類事故的
公開教訓是：只讀 metadata，不讀秘密本體；任何疑似曝光的 credential
都立即撤銷或更換。規則見 [SAFETY](SAFETY.md) §8.2。

## 只有實機才看得出來的三件事

自動測試通過不代表使用者看到的是對的。這三個是 0.2.8 實機驗收才發現的：

**合併模式沒有個別 `NSStatusItem` 是正常結構**，設定頁不該因此顯示「未啟用」。測試斷言「項目存在」時很容易把這種合法狀態誤判成故障。

**可重用的設定視窗若不加入 `moveToActiveSpace`**，重新開啟時會把使用者帶回第一次開啟它的桌面，而不是目前這個。

**popover 固定高度會產生不必要的 scrollbar。** 現在先量自然高度，螢幕放得下就完整展開。
