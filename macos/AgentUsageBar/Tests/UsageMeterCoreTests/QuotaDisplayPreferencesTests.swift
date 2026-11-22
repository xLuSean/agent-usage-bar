import Testing
import UsageMeterCore

struct QuotaDisplayPreferencesTests {
    @Test("詳情面板依所選週期篩選一般額度和模型額度", arguments: [ProviderKind.claude, .antigravity])
    func popoverWindowsByKind(provider: ProviderKind) {
        let session = [window(.session, group: .session), window(.sessionScoped, group: .session)]
        let weekly = [window(.weeklyAll, group: .weekly), window(.weeklyScoped, group: .weekly)]
        let other = window(.unrecognized("monthly"), group: .unrecognized("monthly"))
        let windows = session + weekly + [other]

        #expect(windows.filter { QuotaWindowDisplayMode.sessionOnly.includesInPopover($0, provider: provider) } == session)
        #expect(windows.filter { QuotaWindowDisplayMode.weeklyOnly.includesInPopover($0, provider: provider) } == weekly)
        #expect(windows.filter { QuotaWindowDisplayMode.both.includesInPopover($0, provider: provider) } == windows)
    }

    @Test("Codex 單窗詳情以實際時長篩選，涵蓋舊快照和未提供時長")
    func codexPopoverWindowsByDuration() {
        let session = window(.weeklyAll, group: .weekly, durationMinutes: 300)
        let weekly = window(.session, group: .session, durationMinutes: 10_080)
        let other = window(.unrecognized("codex_primary"), group: .unrecognized("other"), durationMinutes: 15)
        let missingDuration = window(.session, group: .session)
        let windows = [session, weekly, other, missingDuration]

        #expect(windows.filter { QuotaWindowDisplayMode.sessionOnly.includesInPopover($0, provider: .codex) } == [session])
        #expect(windows.filter { QuotaWindowDisplayMode.weeklyOnly.includesInPopover($0, provider: .codex) } == [weekly])
        #expect(windows.filter { QuotaWindowDisplayMode.both.includesInPopover($0, provider: .codex) } == windows)
    }

    private func window(
        _ kind: UsageWindow.Kind,
        group: UsageWindow.Group,
        durationMinutes: Int? = nil
    ) -> UsageWindow {
        UsageWindow(
            kind: kind,
            group: group,
            used: UsedPercent(hundredScale: 42),
            resetsAt: nil,
            isActive: false,
            durationMinutes: durationMinutes
        )
    }
}
