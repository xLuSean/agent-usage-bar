import Foundation
import Testing
@testable import UsageMeterCore

@Suite("面板長條的收放狀態")
struct WindowDisclosureTests {

    private static func window(
        _ kind: UsageWindow.Kind,
        model: String? = nil
    ) -> UsageWindow {
        UsageWindow(
            kind: kind,
            group: kind == .session ? .session : .weekly,
            used: UsedPercent(hundredScale: 12),
            resetsAt: nil,
            isActive: false,
            modelDisplayName: model
        )
    }

    private static let session = window(.session)
    private static let weekly = window(.weeklyAll)
    private static let scoped = window(.weeklyScoped, model: "Example Model")

    @Test("5 小時與 7 天預設展開，模型專屬上限預設收合")
    func defaultsFollowTheKind() {
        let disclosure = WindowDisclosure()

        #expect(disclosure.isCollapsed(Self.session, provider: .claude) == false)
        #expect(disclosure.isCollapsed(Self.weekly, provider: .claude) == false)
        #expect(disclosure.isCollapsed(Self.scoped, provider: .claude))
        // A limit this build has never seen is shown whole the first time.
        #expect(disclosure.isCollapsed(Self.window(.unrecognized("monthly_all")), provider: .claude) == false)
        #expect(disclosure.storedValue.isEmpty)
    }

    @Test("每一列各自收放，互不影響")
    func rowsToggleIndependently() {
        var disclosure = WindowDisclosure()

        disclosure.toggle(Self.session, provider: .claude)
        #expect(disclosure.isCollapsed(Self.session, provider: .claude))
        #expect(disclosure.isCollapsed(Self.weekly, provider: .claude) == false)
        #expect(disclosure.isCollapsed(Self.scoped, provider: .claude))

        disclosure.toggle(Self.scoped, provider: .claude)
        #expect(disclosure.isCollapsed(Self.scoped, provider: .claude) == false)
        #expect(disclosure.isCollapsed(Self.session, provider: .claude))
    }

    /// Both providers have a session window and a weekly window.
    @Test("收合 Claude 的列不會收合 Codex 的同名列")
    func providersDoNotShareRows() {
        var disclosure = WindowDisclosure()
        disclosure.toggle(Self.weekly, provider: .claude)

        #expect(disclosure.isCollapsed(Self.weekly, provider: .claude))
        #expect(disclosure.isCollapsed(Self.weekly, provider: .codex) == false)
    }

    /// Two per-model rows share a kind and differ only in label.
    @Test("不同模型的上限是不同的列")
    func scopedRowsAreKeyedByLabel() {
        var disclosure = WindowDisclosure()
        let other = Self.window(.weeklyScoped, model: "Another Model")
        disclosure.toggle(Self.scoped, provider: .claude)

        #expect(disclosure.isCollapsed(Self.scoped, provider: .claude) == false)
        #expect(disclosure.isCollapsed(other, provider: .claude))
    }

    @Test("回到預設狀態時不留下紀錄")
    func returningToTheDefaultStoresNothing() {
        var disclosure = WindowDisclosure()
        disclosure.toggle(Self.session, provider: .claude)
        #expect(disclosure.storedValue == ["claude/session": true])

        disclosure.toggle(Self.session, provider: .claude)
        #expect(disclosure.storedValue.isEmpty)
        #expect(disclosure == WindowDisclosure())
    }

    @Test("存下來再讀回來完全一致")
    func roundTripsThroughPreferences() throws {
        let suite = "WindowDisclosureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var disclosure = WindowDisclosure()
        disclosure.toggle(Self.session, provider: .claude)
        disclosure.toggle(Self.scoped, provider: .claude)
        defaults.set(disclosure.storedValue, forKey: "disclosure")

        let restored = WindowDisclosure(storedValue: defaults.dictionary(forKey: "disclosure"))
        #expect(restored == disclosure)
        #expect(restored.isCollapsed(Self.session, provider: .claude))
        #expect(restored.isCollapsed(Self.scoped, provider: .claude) == false)
    }

    @Test("損壞或超量的保存值視為沒有偏好")
    func rejectsAMalformedStoredValue() {
        let oversized = Dictionary(
            uniqueKeysWithValues: (0...WindowDisclosure.maximumOverrides).map { ("claude/row\($0)", true) }
        )
        let malformed: [Any?] = [
            nil,
            "collapsed",
            ["claude/session": "yes"],
            ["claude/session\u{202E}": true],
            ["": true],
            oversized,
        ]
        for stored in malformed {
            #expect(WindowDisclosure(storedValue: stored) == WindowDisclosure())
        }
    }

    /// The label is provider text. A row whose identity is not safe to store keeps its
    /// default rather than being remembered under an unsafe key.
    @Test("身分不安全的列維持預設，不寫入偏好")
    func neverStoresAnUnsafeKey() {
        var disclosure = WindowDisclosure()
        let unsafe = Self.window(.weeklyScoped, model: "Evil\u{202E}Name")

        disclosure.toggle(unsafe, provider: .claude)

        #expect(disclosure.storedValue.isEmpty)
        #expect(disclosure.isCollapsed(unsafe, provider: .claude))
    }

    @Test("紀錄筆數有上限")
    func boundsTheNumberOfOverrides() {
        var disclosure = WindowDisclosure()
        for index in 0..<(WindowDisclosure.maximumOverrides + 20) {
            disclosure.toggle(Self.window(.weeklyScoped, model: "Model \(index)"), provider: .claude)
        }

        #expect(disclosure.storedValue.count == WindowDisclosure.maximumOverrides)
        // The newest choice is always kept; something older made room for it.
        let newest = Self.window(.weeklyScoped, model: "Model \(WindowDisclosure.maximumOverrides + 19)")
        #expect(disclosure.isCollapsed(newest, provider: .claude) == false)
    }
}
