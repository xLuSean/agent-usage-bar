import Foundation
import Testing
@testable import UsageMeterCore

@Suite("量表視覺語言")
struct GaugeStyleTests {

    func window(used: Double) -> UsageWindow {
        UsageWindow(
            kind: .session, group: .session,
            used: UsedPercent(hundredScale: used),
            resetsAt: nil, isActive: true
        )
    }

    func snapshot(_ window: UsageWindow) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude, sourcePath: .fixture,
            windows: [window], fetchedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// The server's own verdict is coarser than the number: it called a window at 58%
    /// consumed "normal", which painted a half-spent bar green while the label beside
    /// it read 58%. Colour now follows the figure so the two cannot disagree.
    @Test("顏色只看百分比，不受上游 severity 影響")
    func colourFollowsTheNumberOnly() {
        #expect(GaugeStyleResolver.fillLevel(for: window(used: 58)) == .caution)
        #expect(GaugeStyleResolver.fillLevel(for: window(used: 10)) == .ok)
        #expect(GaugeStyleResolver.fillLevel(for: window(used: 90)) == .critical)
    }

    @Test("本地門檻的邊界值（以已用百分比為準）")
    func localThresholdBoundaries() {
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 0) == .ok)
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 49) == .ok)
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 50) == .caution)
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 79) == .caution)
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 80) == .critical)
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 99) == .critical)
        #expect(GaugeStyleResolver.localFillLevel(usedPercent: 100) == .exhausted)
    }

    @Test("100% 是自己的狀態，即使上游說 normal")
    func exhaustedIsItsOwnLevel() {
        #expect(GaugeStyleResolver.fillLevel(for: window(used: 100)) == .exhausted)
    }

    @Test("未知資料絕不畫成 0%")
    func unknownIsNotZero() {
        let unavailable = GaugeStyleResolver.renderModel(provider: .claude, state: .unavailable(.claudeNotSignedIn))
        #expect(unavailable.session.fillLevel == .unknown)
        #expect(unavailable.weekly.fillLevel == .unknown)
        #expect(unavailable.frameStyle == .dashedEmpty)

        let exhausted = GaugeStyleResolver.renderModel(
            provider: .claude,
            state: .current(snapshot(window(used: 100)))
        )
        #expect(exhausted.session.fillLevel == .exhausted)
        // Unknown and exhausted must not share a look.
        #expect(unavailable.session.fillLevel != exhausted.session.fillLevel)
        #expect(unavailable.frameStyle != exhausted.frameStyle)
    }

    @Test("限流與一般過期在視覺上必須可區分")
    func throttledIsVisuallyDistinctFromStale() {
        let base = snapshot(window(used: 40))
        let stale = GaugeStyleResolver.frameStyle(for: .stale(base, reason: .offline))
        let throttled = GaugeStyleResolver.frameStyle(for: .throttled(previous: base, until: Date()))
        #expect(stale == .staleMarked)
        #expect(throttled == .throttledStriped)
        #expect(stale != throttled)
    }

    @Test("身分不只靠顏色：每個供應商都有字母線索且彼此不同")
    func nonColorIdentityCue() {
        let letters = ProviderKind.allCases.map(\.identityLetter)
        #expect(letters.allSatisfy { !$0.isEmpty })
        #expect(Set(letters).count == ProviderKind.allCases.count)
        #expect(GaugeStyleResolver.renderModel(provider: .claude, state: .starting).glyph == "C")
        #expect(GaugeStyleResolver.renderModel(provider: .codex, state: .starting).glyph == "X")
    }

    @Test("填色高度等於已用比例：量表隨消耗往上長，不是往下退")
    func fillFractionTracksConsumption() {
        let model = GaugeStyleResolver.renderModel(
            provider: .claude,
            state: .current(snapshot(window(used: 29)))
        )
        #expect(model.session.fillFraction == 0.29)
    }

    @Test("兩個量表獨立，不把模型週額度或官方代表項目放進另一半")
    func independentQuotaSlots() {
        let windows = [
            UsageWindow(kind: .weeklyScoped, group: .weekly, used: UsedPercent(hundredScale: 99), resetsAt: nil, isActive: true, modelDisplayName: "Example"),
            UsageWindow(kind: .weeklyAll, group: .weekly, used: UsedPercent(hundredScale: 68), resetsAt: nil, isActive: false),
            window(used: 28),
        ]
        let snapshot = UsageSnapshot(provider: .claude, sourcePath: .fixture, windows: windows, fetchedAt: Date())
        let model = GaugeStyleResolver.renderModel(provider: .claude, state: .current(snapshot))
        #expect(model.session.fillFraction == 0.28)
        #expect(model.session.fillLevel == .ok)
        #expect(model.weekly.fillFraction == 0.68)
        #expect(model.weekly.fillLevel == .caution)
        #expect(model.accessibilityLabel.contains("28% used"))
        #expect(model.accessibilityLabel.contains("68% used"))
        #expect(!model.accessibilityLabel.contains("99%"))
    }

    @Test("0%、未回報與官方未列出限制是不同狀態")
    func zeroMissingAndNotListedAreDistinct() {
        let base = snapshot(window(used: 0))
        let model = GaugeStyleResolver.renderModel(provider: .claude, state: .current(base))
        #expect(model.session.availability == .reported)
        #expect(model.session.fillFraction == 0)
        #expect(model.weekly.availability == .unknown)
        #expect(model.weekly.fillLevel == .unknown)
        let noSession = UsageSnapshot(provider: .claude, sourcePath: .claudeCodeCLI, windows: [], fetchedAt: Date(), claudeLimitListReported: true)
        let absent = GaugeStyleResolver.renderModel(provider: .claude, state: .current(noSession))
        #expect(absent.session.availability == .notListed)
        #expect(absent.weekly.availability == .notListed)
        #expect(!absent.accessibilityLabel.contains("0%"))
    }

    @Test("舊 Codex 快照的主要窗若是週額度，只能進入右半")
    func legacyCodexDurationWinsOverPosition() {
        let legacy = UsageWindow(kind: .session, group: .session, used: UsedPercent(hundredScale: 51), resetsAt: nil, isActive: true, durationMinutes: 10_080)
        let base = UsageSnapshot(provider: .codex, sourcePath: .codexAppServer, windows: [legacy], fetchedAt: Date())
        let model = GaugeStyleResolver.renderModel(provider: .codex, state: .current(base))
        #expect(model.session.availability == .unknown)
        #expect(model.weekly.fillFraction == 0.51)
    }

    @Test("個別時間窗過了重設時間只降低該半邊的可信度")
    func resetBoundariesAreIndependent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let windows = [
            UsageWindow(kind: .session, group: .session, used: UsedPercent(hundredScale: 91), resetsAt: now.addingTimeInterval(-61), isActive: false),
            UsageWindow(kind: .weeklyAll, group: .weekly, used: UsedPercent(hundredScale: 30), resetsAt: now.addingTimeInterval(3_600), isActive: false),
        ]
        let base = UsageSnapshot(provider: .claude, sourcePath: .fixture, windows: windows, fetchedAt: now)
        let model = GaugeStyleResolver.renderModel(provider: .claude, state: .current(base), now: now)
        #expect(model.session.frameStyle == .staleMarked)
        #expect(model.weekly.frameStyle == .solid)
        #expect(model.accessibilityLabel.contains("past reset"))
    }

    @Test("VoiceOver 標籤在每種狀態下都說得出發生什麼事")
    func accessibilityLabels() {
        let base = snapshot(window(used: 93))
        let english = Locale(identifier: "en_US")
        let current = GaugeStyleResolver.accessibilityLabel(
            provider: .claude, state: .current(base), locale: english
        )
        #expect(current.contains("93%"))
        #expect(current.contains("used"))
        #expect(current.contains("Claude"))
        #expect(current.contains("7% remaining"))
        let currentChinese = GaugeStyleResolver.accessibilityLabel(
            provider: .claude, state: .current(base), locale: Locale(identifier: "zh_Hant_TW")
        )
        #expect(currentChinese.contains("剩餘約 7%"))

        let unavailable = GaugeStyleResolver.accessibilityLabel(
            provider: .claude, state: .unavailable(.claudeNotSignedIn), locale: english
        )
        #expect(unavailable.contains("unknown"))
        #expect(unavailable.contains("Not signed in"))

        let throttled = GaugeStyleResolver.accessibilityLabel(
            provider: .claude,
            state: .throttled(previous: base, until: Date().addingTimeInterval(900)),
            locale: english
        )
        #expect(throttled.contains("rate limited"))

        let chinese = GaugeStyleResolver.accessibilityLabel(
            provider: .claude,
            state: .unavailable(.claudeNotSignedIn),
            locale: Locale(identifier: "zh_Hant_TW")
        )
        #expect(chinese.contains("額度未知"))
        #expect(chinese.contains("未登入"))
    }
}

@Suite("選單列顯示哪一個時間窗")
struct RepresentativeWindowTests {

    func snapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, sourcePath: .usageEndpoint,
                      windows: windows, fetchedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    func window(_ kind: UsageWindow.Kind, used: Double, isActive: Bool) -> UsageWindow {
        UsageWindow(kind: kind, group: kind == .session ? .session : .weekly,
                    used: UsedPercent(hundredScale: used), resetsAt: nil,
                    isActive: isActive)
    }

    /// The behaviour that prompted the change: a weekly window can hold `is_active` for
    /// days, so the gauge sat on a slow-moving number while the five-hour window — the
    /// one that stops work within the hour — was invisible.
    @Test("週窗是綁定限制時，量表仍顯示 5 小時窗")
    func shortWindowWinsOverBindingWeekly() throws {
        let snap = snapshot([
            window(.weeklyAll, used: 76, isActive: true),
            window(.session, used: 30, isActive: false),
        ])
        #expect(snap.representativeWindow?.kind == .session)
        #expect(snap.representativeWindow?.used.usedPercent == 30)
        #expect(GaugeStyleResolver.renderModel(provider: .claude, state: .current(snap)).session.fillFraction == 0.30)
    }

    @Test("沒有 5 小時窗時退回綁定的那個")
    func fallsBackToBinding() throws {
        let snap = snapshot([
            window(.weeklyScoped, used: 40, isActive: false),
            window(.weeklyAll, used: 76, isActive: true),
        ])
        #expect(snap.representativeWindow?.isActive == true)
    }

    @Test("都沒有時退回第一個，不會回 nil")
    func fallsBackToFirst() throws {
        let snap = snapshot([window(.unrecognized("monthly"), used: 12, isActive: false)])
        #expect(snap.representativeWindow != nil)
    }

    @Test("完全沒有時間窗才回 nil")
    func emptyIsNil() {
        #expect(snapshot([]).representativeWindow == nil)
    }
}
