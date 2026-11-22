import Foundation

/// Which quota windows a surface (menu bar icon or detail popover) displays.
///
/// Stored independently for the menu bar and the popover so the menu bar can stay
/// compact (for instance, 5 hours only or 7 days only) while clicking it still opens
/// the full breakdown.
public enum QuotaWindowDisplayMode: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {
    case both
    case sessionOnly
    case weeklyOnly

    public var id: String { rawValue }

    public var includesSession: Bool {
        self == .both || self == .sessionOnly
    }

    public var includesWeekly: Bool {
        self == .both || self == .weeklyOnly
    }

    /// The full detail view includes every readable quota period.
    public func includesInPopover(_ window: UsageWindow, provider: ProviderKind) -> Bool {
        guard self != .both else { return true }

        if provider == .codex {
            // Older Codex snapshots could infer the kind from the primary or secondary slot.
            return (includesSession && window.durationMinutes == 300)
                || (includesWeekly && window.durationMinutes == 10_080)
        }

        return switch window.kind {
        case .session, .sessionScoped:
            includesSession
        case .weeklyAll, .weeklyScoped:
            includesWeekly
        case .unrecognized:
            false
        }
    }

    public var displayName: String {
        displayName(locale: Locale(identifier: "en_US"))
    }

    public func displayName(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return switch self {
            case .both: "5 小時與 7 天"
            case .sessionOnly: "僅 5 小時"
            case .weeklyOnly: "僅 7 天"
            }
        }
        return switch self {
        case .both: "5 hours & 7 days"
        case .sessionOnly: "5 hours only"
        case .weeklyOnly: "7 days only"
        }
    }
}

/// Which Antigravity model group drives the compact menu bar gauge.
///
/// Antigravity partitions quota by model group (for example, Gemini Models vs. Claude
/// and GPT models) with no single all-models pool. This preference lets the menu bar
/// pin one group or track the highest consumed group, independently of what the
/// popover displays.
public enum AntigravityToolbarGroupSelection: Sendable, Hashable, Codable {
    public static let defaultGroupName = "Gemini Models"
    private static let highestUsedToken = "__highest_used__"

    case highestUsed
    case group(String)

    public static var `default`: Self { .group(defaultGroupName) }

    public var storedValue: String {
        switch self {
        case .highestUsed: Self.highestUsedToken
        case .group(let name): name
        }
    }

    public init(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else {
            self = .default
            return
        }
        if storedValue == Self.highestUsedToken {
            self = .highestUsed
            return
        }
        if let safe = ProviderMetadataText.normalizedDisplay(storedValue) {
            self = .group(safe)
        } else {
            self = .default
        }
    }

    public func displayName(locale: Locale) -> String {
        switch self {
        case .highestUsed:
            TimeFormatting.usesTraditionalChinese(locale)
                ? "最高用量群組"
                : "Highest used group"
        case .group(let name):
            name
        }
    }
}

/// Which Antigravity model groups appear inside the detail popover.
///
/// Kept separate from `AntigravityToolbarGroupSelection` so clicking a compact menu
/// bar gauge can still show every model group returned by `agy /usage`.
public enum AntigravityPopoverGroupSelection: Sendable, Hashable, Codable {
    private static let allToken = "__all__"

    case all
    case group(String)

    public static var `default`: Self { .all }

    public var storedValue: String {
        switch self {
        case .all: Self.allToken
        case .group(let name): name
        }
    }

    public init(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else {
            self = .default
            return
        }
        if storedValue == Self.allToken {
            self = .all
            return
        }
        if let safe = ProviderMetadataText.normalizedDisplay(storedValue) {
            self = .group(safe)
        } else {
            self = .default
        }
    }

    public func displayName(locale: Locale) -> String {
        switch self {
        case .all:
            TimeFormatting.usesTraditionalChinese(locale)
                ? "所有群組"
                : "All groups"
        case .group(let name):
            name
        }
    }
}
