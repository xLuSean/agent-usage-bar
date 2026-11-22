import Foundation

/// Which provider a snapshot came from. Both status items are independent, so
/// this rides along with the data rather than being inferred from context.
public enum ProviderKind: String, Sendable, Hashable, CaseIterable, Codable {
    case claude
    case codex
    case antigravity

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// The identity cue that does not depend on colour. Colour alone must never be the
    /// only carrier of identity — two similar custom colours, or a colour-vision
    /// difference, and the gauges become indistinguishable.
    public var identityLetter: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .antigravity: "A"
        }
    }
}

/// How the numbers were obtained. Surfaced in the UI because the routes differ in
/// ways the reader should be able to see — synthetic demo data most of all.
public enum UsageSourcePath: String, Sendable, Hashable, Codable {
    /// Claude Code's own `/usage` command, run read-only as a one-shot subprocess.
    /// The current Claude path.
    case claudeCodeCLI
    /// `GET /api/oauth/usage` — retired in 0.3.0, see `docs/LEGACY_KEYCHAIN_PATH.md`.
    ///
    /// Kept decodable, not merely for tidiness: `UsageSnapshotStore` persists a snapshot
    /// across launches, so the first launch after an upgrade reads one written by the
    /// previous version. Removing the case would make that stored reading fail to
    /// decode, and the app would open with no data for no reason the user could see.
    case usageEndpoint
    /// `POST /v1/messages` rate-limit headers. Retired alongside `usageEndpoint`, and
    /// kept decodable for the same reason.
    case messagesFallback
    /// Codex `account/rateLimits/read` over the local app-server.
    case codexAppServer
    /// Antigravity CLI's read-only `/usage` command, run as a one-shot subprocess.
    case antigravityCLI
    /// Synthetic data. Never a live reading.
    case fixture

    /// Whether this app can still produce readings by this route. The retired paths
    /// decode but are never written again.
    public var isRetired: Bool {
        switch self {
        case .usageEndpoint, .messagesFallback: true
        default: false
        }
    }

    public var displayName: String {
        displayName(locale: Locale(identifier: "en_US"))
    }

    public func displayName(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return switch self {
            case .claudeCodeCLI: "Claude Code /usage"
            case .usageEndpoint: "usage 端點（已退場）"
            case .messagesFallback: "fallback（已退場）"
            case .codexAppServer: "Codex app-server"
            case .antigravityCLI: "Antigravity CLI /usage"
            case .fixture: "fixture（示範資料）"
            }
        }
        return switch self {
        case .claudeCodeCLI: "Claude Code /usage"
        case .usageEndpoint: "usage endpoint (retired)"
        case .messagesFallback: "fallback (retired)"
        case .codexAppServer: "Codex app-server"
        case .antigravityCLI: "Antigravity CLI /usage"
        case .fixture: "fixture (demo data)"
        }
    }
}

/// Credit information volunteered by a provider. `nil` on `UsageSnapshot` means the
/// service did not provide the field; it must not be presented as a zero balance.
public struct UsageCredits: Sendable, Hashable, Codable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public var displayDescription: String {
        displayDescription(locale: Locale(identifier: "en_US"))
    }

    public func displayDescription(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            if unlimited { return "無上限" }
            if let balance { return balance }
            return hasCredits ? "可用（未提供餘額）" : "無可用 Credits"
        }
        if unlimited { return "Unlimited" }
        if let balance { return balance }
        return hasCredits ? "Available (balance unavailable)" : "No available Credits"
    }
}

/// One complete reading. Each fetch replaces the last; nothing is accumulated locally,
/// so there is no sample store and no forecast. Codex may include provider-maintained
/// daily account totals inside this latest snapshot.
public struct UsageSnapshot: Sendable, Hashable, Codable {
    public let provider: ProviderKind
    public let sourcePath: UsageSourcePath
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    /// Optional provider metadata. These are diagnostics or detail rows; none changes
    /// the shared gauge colour or state semantics.
    public let credits: UsageCredits?
    public let planType: String?
    public let rateLimitReachedType: String?
    public let spendControlReached: Bool?
    public let meteredLimitID: String?
    public let sourceVersion: String?
    /// Optional Codex account totals from `account/usage/read`. Never derived from local
    /// task files. `nil` means the endpoint or a trustworthy payload was unavailable.
    public let codexAccountUsage: CodexAccountUsage?
    /// A structured Claude report supplied an actual limit list, including an empty
    /// list. Missing rows then mean "not listed by the service", never zero or an
    /// unlimited allowance. Nil preserves the stricter legacy/prose contract.
    public let claudeLimitListReported: Bool?

    public init(
        provider: ProviderKind,
        sourcePath: UsageSourcePath,
        windows: [UsageWindow],
        fetchedAt: Date,
        credits: UsageCredits? = nil,
        planType: String? = nil,
        rateLimitReachedType: String? = nil,
        spendControlReached: Bool? = nil,
        meteredLimitID: String? = nil,
        sourceVersion: String? = nil,
        codexAccountUsage: CodexAccountUsage? = nil,
        claudeLimitListReported: Bool? = nil
    ) {
        self.provider = provider
        self.sourcePath = sourcePath
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.credits = credits
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControlReached = spendControlReached
        self.meteredLimitID = meteredLimitID
        self.sourceVersion = sourceVersion
        self.codexAccountUsage = codexAccountUsage
        self.claudeLimitListReported = claudeLimitListReported
    }

    /// Convenience for consumers needing one row. The menu bar does not use this:
    /// its two fixed slots must never substitute one quota for the other.
    public var representativeWindow: UsageWindow? {
        windows.first { $0.kind == .session }
            ?? windows.first { $0.isActive }
            ?? windows.first
    }

    /// The two general quotas, independently selected. Codex's nullable duration must
    /// be known before a reading may be labelled five hours or seven days. Antigravity
    /// partitions quota by model group, so its selection honours the chosen toolbar group.
    public func quotaWindow(
        for kind: UsageWindow.Kind,
        antigravityGroup: AntigravityToolbarGroupSelection = .default
    ) -> UsageWindow? {
        if provider == .antigravity {
            return antigravityQuotaWindow(for: kind, selection: antigravityGroup)
        }
        let matches = windows.filter { window in
            if provider == .codex {
                guard meteredLimitID == nil || meteredLimitID == "codex",
                      window.modelDisplayName == nil else { return false }
                switch kind {
                case .session: return window.durationMinutes == 300
                case .weeklyAll: return window.durationMinutes == 10_080
                default: return false
                }
            }
            return window.kind == kind
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Distinct Antigravity model group names in the order returned by the provider.
    public var antigravityGroupNames: [String] {
        guard provider == .antigravity else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for window in windows {
            if let name = window.modelDisplayName, seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// The resolved Antigravity group name for a toolbar selection, if present in this snapshot.
    public func resolvedAntigravityToolbarGroup(
        selection: AntigravityToolbarGroupSelection
    ) -> String? {
        guard provider == .antigravity else { return nil }
        let groups = antigravityGroupNames
        guard !groups.isEmpty else { return nil }
        switch selection {
        case .highestUsed:
            return nil
        case .group(let requested):
            if groups.contains(requested) { return requested }
            if groups.contains(AntigravityToolbarGroupSelection.defaultGroupName) {
                return AntigravityToolbarGroupSelection.defaultGroupName
            }
            return groups.first
        }
    }

    private func antigravityQuotaWindow(
        for kind: UsageWindow.Kind,
        selection: AntigravityToolbarGroupSelection
    ) -> UsageWindow? {
        let matchingPeriod = windows.filter { window in
            switch kind {
            case .session:
                window.kind == .session || window.kind == .sessionScoped || window.durationMinutes == 300
            case .weeklyAll:
                window.kind == .weeklyAll || window.kind == .weeklyScoped || window.durationMinutes == 10_080
            default:
                false
            }
        }
        guard !matchingPeriod.isEmpty else { return nil }

        switch selection {
        case .highestUsed:
            return matchingPeriod.max { lhs, rhs in
                lhs.used.normalized < rhs.used.normalized
            }
        case .group:
            if let group = resolvedAntigravityToolbarGroup(selection: selection) {
                let inGroup = matchingPeriod.filter { $0.modelDisplayName == group }
                return inGroup.count == 1 ? inGroup.first : nil
            }
            let unscoped = matchingPeriod.filter { $0.modelDisplayName == nil }
            return unscoped.count == 1 ? unscoped.first : nil
        }
    }

    public func isQuotaNotListed(_ kind: UsageWindow.Kind) -> Bool {
        provider == .claude && claudeLimitListReported == true
            && !windows.contains { $0.kind == kind }
    }

    /// Windows in a stable display order regardless of upstream array order.
    public var orderedWindows: [UsageWindow] {
        if provider == .antigravity {
            // Preserve upstream group order, with 5h before weekly within each group.
            let groupRank = Dictionary(
                uniqueKeysWithValues: antigravityGroupNames.enumerated().map { ($0.element, $0.offset) }
            )
            return windows.sorted { lhs, rhs in
                let lg = lhs.modelDisplayName.flatMap { groupRank[$0] } ?? Int.max
                let rg = rhs.modelDisplayName.flatMap { groupRank[$0] } ?? Int.max
                if lg != rg { return lg < rg }
                return Self.kindRank(lhs.kind) < Self.kindRank(rhs.kind)
            }
        }
        return windows.sorted { lhs, rhs in
            let lr = Self.kindRank(lhs.kind)
            let rr = Self.kindRank(rhs.kind)
            if lr != rr { return lr < rr }
            return (lhs.modelDisplayName ?? "") < (rhs.modelDisplayName ?? "")
        }
    }

    private static func kindRank(_ kind: UsageWindow.Kind) -> Int {
        switch kind {
        case .session: 0
        case .sessionScoped: 1
        case .weeklyAll: 2
        case .weeklyScoped: 3
        case .unrecognized: 4
        }
    }

    /// Replaces only Codex's independently refreshed account-token statistics. Quota
    /// fields and their successful-read timestamp remain authoritative and unchanged.
    public func replacingCodexAccountUsage(_ accountUsage: CodexAccountUsage) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            sourcePath: sourcePath,
            windows: windows,
            fetchedAt: fetchedAt,
            credits: credits,
            planType: planType,
            rateLimitReachedType: rateLimitReachedType,
            spendControlReached: spendControlReached,
            meteredLimitID: meteredLimitID,
            sourceVersion: sourceVersion,
            codexAccountUsage: accountUsage,
            claudeLimitListReported: claudeLimitListReported
        )
    }
}
