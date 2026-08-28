import Foundation

/// Which provider a snapshot came from. Both status items are independent, so
/// this rides along with the data rather than being inferred from context.
public enum ProviderKind: String, Sendable, Hashable, CaseIterable, Codable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The identity cue that does not depend on colour. Colour alone must never be the
    /// only carrier of identity — two similar custom colours, or a colour-vision
    /// difference, and the two gauges become indistinguishable.
    public var identityLetter: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
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
            case .fixture: "fixture（示範資料）"
            }
        }
        return switch self {
        case .claudeCodeCLI: "Claude Code /usage"
        case .usageEndpoint: "usage endpoint (retired)"
        case .messagesFallback: "fallback (retired)"
        case .codexAppServer: "Codex app-server"
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

/// One complete reading. Each fetch replaces the last; nothing is accumulated,
/// so there is no sample store and no forecast.
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
        sourceVersion: String? = nil
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
    }

    /// The window the menu bar gauge shows: the **shortest** one, not the binding one.
    ///
    /// This started as whichever limit is currently binding (`is_active`). In use that
    /// turned out to read wrong: a weekly window can be the
    /// binding limit for days at a stretch, so the gauge sat on a number that barely
    /// moved while the five-hour window — the one that actually stops work within the
    /// hour, and the one that resets soon enough to be worth watching — was invisible.
    ///
    /// A glanceable meter should track the fast-moving figure. The binding limit is
    /// still shown in the popover, badged 目前綁定, where there is room to read it.
    public var representativeWindow: UsageWindow? {
        windows.first { $0.kind == .session }
            ?? windows.first { $0.isActive }
            ?? windows.first
    }

    /// Windows in a stable display order regardless of upstream array order.
    public var orderedWindows: [UsageWindow] {
        windows.sorted { lhs, rhs in
            func rank(_ kind: UsageWindow.Kind) -> Int {
                switch kind {
                case .session: 0
                case .weeklyAll: 1
                case .weeklyScoped: 2
                case .unrecognized: 3
                }
            }
            if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
            return (lhs.modelDisplayName ?? "") < (rhs.modelDisplayName ?? "")
        }
    }
}
