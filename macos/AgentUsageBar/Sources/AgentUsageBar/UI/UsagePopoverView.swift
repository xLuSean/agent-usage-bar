import SwiftUI
import UsageMeterCore

/// The panel behind a menu bar gauge: what the numbers are, how old they are, and the
/// two actions that have to be reachable without a Dock icon.
///
/// Preferences deliberately are not here. A transient popover closes as soon as focus
/// moves, which makes it a bad place to change something and then look at the result;
/// those live in the settings window.
struct UsagePopoverView: View {
    /// One entry in separate mode; every enabled provider in combined mode.
    ///
    /// The combined icon stands for all of them, so clicking it shows all of them.
    /// Picking one to show meant picking a loser: the first attempt ranked by "most in
    /// need of attention", and an unimplemented provider is permanently in need of
    /// attention, so it won every time and the working provider became unreachable.
    let presenters: [ProviderPresenter]
    let language: AppLanguage
    let onOpenSettings: () -> Void
    /// The controller measures the unscrolled view first. Scrolling is enabled only
    /// when the natural height is taller than the current screen can display.
    let allowsScrolling: Bool

    init(
        presenters: [ProviderPresenter],
        language: AppLanguage = .english,
        allowsScrolling: Bool = true,
        onOpenSettings: @escaping () -> Void
    ) {
        self.presenters = presenters
        self.language = language
        self.allowsScrolling = allowsScrolling
        self.onOpenSettings = onOpenSettings
    }

    init(
        presenter: ProviderPresenter,
        language: AppLanguage = .english,
        allowsScrolling: Bool = true,
        onOpenSettings: @escaping () -> Void
    ) {
        self.init(
            presenters: [presenter],
            language: language,
            allowsScrolling: allowsScrolling,
            onOpenSettings: onOpenSettings
        )
    }

    var body: some View {
        // The footer sits outside the scroll view: §7.3 makes 重新整理 and 結束 App
        // required, and with no Dock icon, 結束 App is the only way to quit — neither
        // may end up below the fold.
        VStack(spacing: 0) {
            if allowsScrolling {
                ScrollView { providerContent }
            } else {
                providerContent
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 320)
        .environment(\.locale, language.locale)
    }

    private var providerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(presenters.enumerated()), id: \.element.provider) { index, presenter in
                if index > 0 {
                    Divider().padding(.vertical, 2)
                }
                ProviderSection(presenter: presenter, language: language)
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") {
                // Refreshes everything on show, not just the first — the button sits
                // under all of them.
                for presenter in presenters {
                    presenter.requestRefresh(reason: .manual)
                }
            }
            Button("Settings…", action: onOpenSettings)
            Spacer()
            Button("Quit App") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// Everything shown for one provider. Repeated per provider in combined mode.
private struct ProviderSection: View {
    @Bindable var presenter: ProviderPresenter
    let language: AppLanguage
    @State private var didCopyLoginCommand = false

    private func credentialRecoveryAction(command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                didCopyLoginCommand = pasteboard.setString(
                    command,
                    forType: .string
                )
            } label: {
                Label(
                    didCopyLoginCommand ? "Recovery command copied" : "Copy Claude Code recovery command",
                    systemImage: didCopyLoginCommand ? "checkmark" : "doc.on.doc"
                )
            }
            // One command, one branch. The `setup-token` case that needed
            // `claude auth login` went away with the credential path — this app no
            // longer inspects token scopes.
            Text("Copies `claude`. Paste it into Terminal to launch Claude Code once. If prompted, finish signing in, then return and click Refresh. This app runs the read-only /usage query, but never signs you in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = presenter.state.error {
                ErrorBanner(error: error, hasStaleReading: presenter.state.snapshot != nil, language: language)
            }
            if presenter.provider == .claude,
               let command = ClaudeSignInRecovery.command(for: presenter.state.error) {
                credentialRecoveryAction(command: command)
            }
            windowsSection
            dataStatusSection
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presenter.provider.identityLetter)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color(presenter.settings.identityColor.nsColor))
            Text(presenter.provider.displayName)
                .font(.headline)
            Spacer()
            StatusPill(state: presenter.state, language: language)
        }
    }

    @ViewBuilder
    private var windowsSection: some View {
        if let snapshot = presenter.state.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                // Variable count on purpose: 5h, 7d, and any number of per-model weekly
                // windows. Nothing here assumes exactly two.
                ForEach(snapshot.orderedWindows) { window in
                    WindowRow(
                        window: window,
                        isTrustworthy: presenter.state.isDataTrustworthyAsCurrent,
                        language: language,
                        missingReset: missingResetPresentation(for: window)
                    )
                }
            }
        } else {
            Text("No trustworthy usage data is currently available.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The providers share row layout, not the meaning of a missing field. Claude has
    /// one observed, decoder-enforced gap shape (`0%` session with no reset); Codex's
    /// App Server may simply omit an optional reset timestamp.
    private func missingResetPresentation(for window: UsageWindow) -> MissingResetPresentation {
        switch presenter.provider {
        case .claude where window.kind == .session && window.used.usedPercent == 0:
            MissingResetPresentation(
                text: language.text(
                    chinese: "尚未提供重設時間",
                    english: "No reset time reported yet"
                ),
                help: language.text(
                    chinese: "Claude Code 在目前用量為 0% 時沒有提供重設時間；開始使用後再重新整理即可。",
                    english: "Claude Code reported 0% without a reset time. Refresh after usage begins."
                )
            )
        case .claude, .codex:
            MissingResetPresentation(
                text: language.text(
                    chinese: "重設時間未提供",
                    english: "Reset time unavailable"
                ),
                help: nil
            )
        }
    }

    private var dataStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledRow(
                language.text(chinese: "資料狀態", english: "Data status"),
                presenter.state.statusLabel(locale: language.locale)
            )
            if let snapshot = presenter.state.snapshot {
                LabeledRow(
                    language.text(chinese: "最後成功更新", english: "Last successful update"),
                    TimeFormatting.dateAndTime(snapshot.fetchedAt, locale: language.locale)
                )
                LabeledRow(
                    language.text(chinese: "資料來源", english: "Data source"),
                    snapshot.sourcePath.displayName(locale: language.locale)
                )
                if snapshot.provider == .codex {
                    LabeledRow("Credits", snapshot.credits?.displayDescription(locale: language.locale)
                        ?? language.text(chinese: "服務未提供", english: "Not provided"))
                    if let planType = snapshot.planType {
                        LabeledRow(language.text(chinese: "方案", english: "Plan"), planType)
                    }
                    if let sourceVersion = snapshot.sourceVersion { LabeledRow("App Server", sourceVersion) }
                    if let reached = snapshot.rateLimitReachedType {
                        LabeledRow(language.text(chinese: "上游限制狀態", english: "Upstream limit status"), reached)
                    }
                    if snapshot.spendControlReached == true {
                        LabeledRow(
                            language.text(chinese: "支出控制", english: "Spend control"),
                            language.text(chinese: "已達上限", english: "Limit reached")
                        )
                    }
                }
            }
            if case .throttled(_, let until) = presenter.state {
                let time = TimeFormatting.timeOfDay(until, locale: language.locale)
                let distance = TimeFormatting.relative(from: Date(), to: until, locale: language.locale)
                LabeledRow(
                    language.text(chinese: "預計恢復", english: "Expected recovery"),
                    language.text(chinese: "\(time)（約 \(distance) 後）", english: "\(time) (in about \(distance))")
                )
            }
            if let next = presenter.nextAttemptAt, presenter.consecutiveFailures > 0 {
                let time = TimeFormatting.timeOfDay(next, locale: language.locale)
                LabeledRow(
                    language.text(chinese: "下次嘗試", english: "Next attempt"),
                    language.text(
                        chinese: "\(time)（連續失敗 \(presenter.consecutiveFailures) 次）",
                        english: "\(time) (\(presenter.consecutiveFailures) consecutive failures)"
                    )
                )
            }
        }
    }

}

private struct StatusPill: View {
    let state: UsageDisplayState
    let language: AppLanguage

    var body: some View {
        Text(verbatim: state.statusLabel(locale: language.locale))
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch state {
        case .current: .green.opacity(0.18)
        case .refreshing, .starting: .gray.opacity(0.18)
        case .stale: .orange.opacity(0.20)
        case .throttled: .red.opacity(0.16)
        case .unavailable: .red.opacity(0.20)
        }
    }

    private var foreground: Color {
        switch state {
        case .current: .green
        case .refreshing, .starting: .secondary
        case .stale: .orange
        case .throttled, .unavailable: .red
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let isTrustworthy: Bool
    let language: AppLanguage
    let missingReset: MissingResetPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: window.displayName(locale: language.locale)).font(.callout).bold()
                if window.isActive {
                    Text("Currently binding")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(language.text(
                    chinese: "已用 \(window.used.usedPercent)%",
                    english: "\(window.used.usedPercent)% used"
                ))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(isTrustworthy ? .primary : .secondary)
            }
            ProgressView(value: window.used.usedFraction)
                .tint(Color(GaugeStyleResolver.fillLevel(for: window).fillColor))
            HStack {
                Text(language.text(
                    chinese: "剩 \(window.used.remainingPercent)%",
                    english: "\(window.used.remainingPercent)% remaining"
                ))
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text(language.text(
                        chinese: "重設於 \(TimeFormatting.resetDescription(resetsAt, locale: language.locale))",
                        english: "Resets \(TimeFormatting.resetDescription(resetsAt, locale: language.locale))"
                    ))
                } else {
                    Text(verbatim: missingReset.text)
                        .help(missingReset.help ?? missingReset.text)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MissingResetPresentation {
    let text: String
    let help: String?
}

private struct ErrorBanner: View {
    let error: UsageError
    let hasStaleReading: Bool
    let language: AppLanguage

    private var icon: String {
        if error.isExpectedLimitation { return "wrench.and.screwdriver" }
        return error.isThrottling ? "hourglass" : "exclamationmark.triangle"
    }

    private var tint: Color {
        // A known gap is not an alarm. Painting it red trains the user to ignore red.
        if error.isExpectedLimitation { return .secondary }
        return error.isThrottling ? .orange : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.shortDescription(locale: language.locale), systemImage: icon)
                .font(.callout).bold()
                .foregroundStyle(tint)
            if let remedy = error.remedy(locale: language.locale) {
                Text(remedy).font(.caption).foregroundStyle(.secondary)
            }
            if hasStaleReading {
                Text("The values below are from the last successful query, not the current values.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).multilineTextAlignment(.trailing)
        }
    }
}
