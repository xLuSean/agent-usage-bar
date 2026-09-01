#if DEBUG
import Foundation
import UsageMeterCore

/// Synthetic states compiled only into the Debug diagnostic app. Release has no
/// fixture source selector, provider, or linked fixture module.
enum DemoScenario: String, CaseIterable, Sendable, Identifiable {
    case starting
    case healthy
    case betweenWindows
    case refreshing
    case lowSession
    case exhausted
    case stale
    case throttled
    case notLoggedIn
    case outdatedReading
    case cliNotFound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starting: "Starting"
        case .healthy: "Healthy (5h 29% used)"
        case .betweenWindows: "Between Claude usage windows (0%, no reset)"
        case .refreshing: "Refreshing (showing previous data)"
        case .lowSession: "5h nearly exhausted (92% used)"
        case .exhausted: "Exhausted (100%)"
        case .stale: "Stale (offline)"
        case .throttled: "Rate limited (429)"
        case .notLoggedIn: "Not signed in to Claude Code"
        case .outdatedReading: "Reading is past its reset time"
        case .cliNotFound: "Claude Code CLI not found"
        }
    }

    func state(now: Date = Date(), provider: ProviderKind = .claude) -> UsageDisplayState {
        switch self {
        case .starting:
            return .starting
        case .healthy:
            return .current(Self.snapshot(sessionUsed: 29, weeklyUsed: 62, now: now, provider: provider))
        case .betweenWindows:
            return .current(Self.betweenWindowsSnapshot(now: now, provider: provider))
        case .refreshing:
            return .refreshing(previous: Self.snapshot(
                sessionUsed: 29,
                weeklyUsed: 62,
                now: now.addingTimeInterval(-90),
                provider: provider
            ))
        case .lowSession:
            return .current(Self.snapshot(sessionUsed: 92, weeklyUsed: 74, now: now, provider: provider))
        case .exhausted:
            return .current(Self.snapshot(sessionUsed: 100, weeklyUsed: 91, now: now, provider: provider))
        case .stale:
            return .stale(
                Self.snapshot(
                    sessionUsed: 44,
                    weeklyUsed: 62,
                    now: now.addingTimeInterval(-1_800),
                    provider: provider
                ),
                reason: .offline
            )
        case .throttled:
            return .throttled(
                previous: Self.snapshot(
                    sessionUsed: 44,
                    weeklyUsed: 62,
                    now: now.addingTimeInterval(-420),
                    provider: provider
                ),
                until: now.addingTimeInterval(1_380)
            )
        case .notLoggedIn:
            return .unavailable(.claudeNotSignedIn)
        case .outdatedReading:
            return .unavailable(.claudeUsageOutdated(resetsAt: now.addingTimeInterval(-900)))
        case .cliNotFound:
            return .unavailable(.claudeExecutableNotFound)
        }
    }

    private static func snapshot(
        sessionUsed: Double,
        weeklyUsed: Double,
        now: Date,
        provider: ProviderKind
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            sourcePath: .fixture,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: sessionUsed),
                    resetsAt: now.addingTimeInterval(3_600 * 2 + 780),
                    isActive: true
                ),
                UsageWindow(
                    kind: .weeklyAll,
                    group: .weekly,
                    used: UsedPercent(hundredScale: weeklyUsed),
                    resetsAt: now.addingTimeInterval(3_600 * 63),
                    isActive: false
                ),
                UsageWindow(
                    kind: .weeklyScoped,
                    group: .weekly,
                    used: UsedPercent(hundredScale: min(100, weeklyUsed + 22)),
                    resetsAt: now.addingTimeInterval(3_600 * 63),
                    isActive: false,
                    modelDisplayName: "Opus 5"
                ),
            ],
            fetchedAt: now,
            codexAccountUsage: provider == .codex ? Self.codexAccountUsage(now: now) : nil
        )
    }

    private static func betweenWindowsSnapshot(now: Date, provider: ProviderKind) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            sourcePath: .fixture,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: 0),
                    resetsAt: nil,
                    isActive: false
                ),
                UsageWindow(
                    kind: .weeklyAll,
                    group: .weekly,
                    used: UsedPercent(hundredScale: 62),
                    resetsAt: now.addingTimeInterval(3_600 * 63),
                    isActive: false
                ),
            ],
            fetchedAt: now,
            codexAccountUsage: provider == .codex ? Self.codexAccountUsage(now: now) : nil
        )
    }

    private static func codexAccountUsage(now: Date) -> CodexAccountUsage {
        // More than the default 30-day chart range so render checks visibly prove the
        // UI is slicing provider history rather than drawing every returned bucket.
        let tokenCounts = (0..<61).map { index in
            let wave = (index % 11) + 2
            let trend = index * 650_000
            return wave * 4_800_000 + trend
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let finalDay = calendar.startOfDay(for: now)
        let buckets = tokenCounts.enumerated().map { index, tokens in
            let offset = index - (tokenCounts.count - 1)
            let date = calendar.date(byAdding: .day, value: offset, to: finalDay)!
            return CodexAccountUsage.DailyBucket(
                startDate: formatter.string(from: date),
                tokens: tokens
            )
        }
        return CodexAccountUsage(
            lifetimeTokens: 1_842_500_000,
            peakDailyTokens: tokenCounts.max(),
            dailyUsageBuckets: buckets
        )
    }

}
#endif
