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
    let codexTokenHistoryPeriod: CodexTokenHistoryPeriod
    let now: Date
    let onOpenSettings: () -> Void
    /// The controller measures the unscrolled view first. Scrolling is enabled only
    /// when the natural height is taller than the current screen can display.
    let allowsScrolling: Bool

    init(
        presenters: [ProviderPresenter],
        language: AppLanguage = .english,
        codexTokenHistoryPeriod: CodexTokenHistoryPeriod = .thirtyDays,
        now: Date = Date(),
        allowsScrolling: Bool = true,
        onOpenSettings: @escaping () -> Void
    ) {
        self.presenters = presenters
        self.language = language
        self.codexTokenHistoryPeriod = codexTokenHistoryPeriod
        self.now = now
        self.allowsScrolling = allowsScrolling
        self.onOpenSettings = onOpenSettings
    }

    init(
        presenter: ProviderPresenter,
        language: AppLanguage = .english,
        codexTokenHistoryPeriod: CodexTokenHistoryPeriod = .thirtyDays,
        now: Date = Date(),
        allowsScrolling: Bool = true,
        onOpenSettings: @escaping () -> Void
    ) {
        self.init(
            presenters: [presenter],
            language: language,
            codexTokenHistoryPeriod: codexTokenHistoryPeriod,
            now: now,
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
                ProviderSection(
                    presenter: presenter,
                    language: language,
                    codexTokenHistoryPeriod: codexTokenHistoryPeriod,
                    now: now
                )
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") {
                // Refreshes both independent Codex reads, plus every other provider —
                // the button sits under all sections and means "refresh everything".
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
    let codexTokenHistoryPeriod: CodexTokenHistoryPeriod
    let now: Date
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
            if presenter.provider == .codex, let snapshot = presenter.state.snapshot {
                codexTokenUsageSection(snapshot: snapshot)
            }
            dataStatusSection
        }
    }

    @ViewBuilder
    private func codexTokenUsageSection(snapshot: UsageSnapshot) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text(chinese: "帳號 Token 用量", english: "Account token usage"))
                .font(.callout)
                .bold()

            if let usage = snapshot.codexAccountUsage,
               usage.lifetimeTokens != nil || usage.peakDailyTokens != nil
                    || !usage.dailyUsageBuckets.isEmpty {
                LabeledRow(
                    language.text(chinese: "今天", english: "Today"),
                    usage.tokens(on: now).map(formattedTokenCount)
                        ?? language.text(chinese: "尚未回報", english: "Not reported yet")
                )
                if let lifetimeTokens = usage.lifetimeTokens {
                    LabeledRow(
                        language.text(chinese: "累積 Token", english: "Lifetime tokens"),
                        formattedTokenCount(lifetimeTokens)
                    )
                }
                if let peakDailyTokens = usage.peakDailyTokens {
                    LabeledRow(
                        language.text(chinese: "最高單日", english: "Peak day"),
                        formattedTokenCount(peakDailyTokens)
                    )
                }
                if !usage.dailyUsageBuckets.isEmpty {
                    let visibleBuckets = usage.mostRecentDailyBuckets(
                        limit: codexTokenHistoryPeriod.rawValue
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text(
                            chinese: "每日用量（\(visibleBuckets.count) 天）",
                            english: "Daily usage (\(visibleBuckets.count) days)"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DailyTokenChart(
                            buckets: visibleBuckets,
                            tint: Color(presenter.settings.identityColor.nsColor),
                            language: language
                        )
                    }
                }
                if let updatedThrough = usage.updatedThrough {
                    LabeledRow(
                        language.text(chinese: "資料統計至", english: "Data through"),
                        formattedUsageDate(updatedThrough)
                    )
                }
                if let fetchedAt = usage.fetchedAt {
                    LabeledRow(
                        language.text(chinese: "Token 更新時間", english: "Token updated"),
                        TimeFormatting.dateAndTime(fetchedAt, locale: language.locale)
                    )
                }
            } else {
                Text(language.text(
                    chinese: "目前的 Codex App Server 沒有提供可信的帳號 Token 統計；額度資料仍可正常使用。",
                    english: "The current Codex App Server did not provide trustworthy account token statistics. Quota data remains available."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .opacity(presenter.state.isDataTrustworthyAsCurrent ? 1 : 0.72)
    }

    private func formattedTokenCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formattedUsageDate(_ value: String) -> String {
        let parts = value.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return value }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        )) else { return value }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
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

private struct DailyTokenChart: View {
    let buckets: [CodexAccountUsage.DailyBucket]
    let tint: Color
    let language: AppLanguage
    @State private var hoveredBucketIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        var baseline = Path()
                        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
                        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                        context.stroke(baseline, with: .color(.secondary.opacity(0.25)))

                        guard let maximum = buckets.map(\.tokens).max(), maximum > 0 else { return }
                        let gap: CGFloat = buckets.count > 200 ? 0 : (buckets.count > 80 ? 0.5 : 1)
                        let availableWidth = max(0, size.width - gap * CGFloat(max(0, buckets.count - 1)))
                        let barWidth = max(0.5, availableWidth / CGFloat(buckets.count))

                        for (index, bucket) in buckets.enumerated() {
                            let fraction = CGFloat(bucket.tokens) / CGFloat(maximum)
                            let height = max(bucket.tokens == 0 ? 0 : 1, size.height * fraction)
                            let rect = CGRect(
                                x: CGFloat(index) * (barWidth + gap),
                                y: size.height - height,
                                width: barWidth,
                                height: height
                            )
                            let barColor = hoveredBucketIndex == nil || hoveredBucketIndex == index
                                ? tint
                                : tint.opacity(0.45)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: min(1.5, barWidth / 2)),
                                with: .color(barColor)
                            )
                        }
                    }

                    if let bucket = hoveredBucket {
                        Text(verbatim: tooltipText(for: bucket))
                            .font(.caption2)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: tooltipAlignment
                            )
                            .padding(4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredBucketIndex = bucketIndex(
                            at: location.x,
                            chartWidth: geometry.size.width
                        )
                    case .ended:
                        hoveredBucketIndex = nil
                    }
                }
            }
            .frame(height: 64)
            .accessibilityLabel(language.text(
                chinese: "Codex 每日 Token 用量長條圖，共 \(buckets.count) 天",
                english: "Codex daily token usage bar chart for \(buckets.count) days"
            ))
            .accessibilityHint(language.text(
                chinese: "將滑鼠移到長條上可查看日期與 Token 數",
                english: "Move the pointer over a bar to see its date and token count"
            ))

            if let first = buckets.first?.startDate, let last = buckets.last?.startDate {
                HStack {
                    Text(verbatim: shortDate(first))
                    Spacer()
                    Text(verbatim: shortDate(last))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var hoveredBucket: CodexAccountUsage.DailyBucket? {
        guard let hoveredBucketIndex, buckets.indices.contains(hoveredBucketIndex) else {
            return nil
        }
        return buckets[hoveredBucketIndex]
    }

    private var tooltipAlignment: Alignment {
        guard let hoveredBucketIndex else { return .topLeading }
        return hoveredBucketIndex < buckets.count / 2 ? .topLeading : .topTrailing
    }

    private func bucketIndex(at x: CGFloat, chartWidth: CGFloat) -> Int? {
        guard !buckets.isEmpty, chartWidth > 0, x >= 0, x <= chartWidth else {
            return nil
        }
        let rawIndex = Int((x / chartWidth) * CGFloat(buckets.count))
        return min(rawIndex, buckets.count - 1)
    }

    private func tooltipText(for bucket: CodexAccountUsage.DailyBucket) -> String {
        let date = fullDate(bucket.startDate)
        let tokens = formattedTokenCount(bucket.tokens)
        return language.text(
            chinese: "\(date)：\(tokens) Token",
            english: "\(date): \(tokens) tokens"
        )
    }

    private func fullDate(_ value: String) -> String {
        let parts = value.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return value }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        )) else { return value }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    private func formattedTokenCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return value }
        return language.text(
            chinese: "\(parts[1])月\(parts[2])日",
            english: "\(parts[1])/\(parts[2])"
        )
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
