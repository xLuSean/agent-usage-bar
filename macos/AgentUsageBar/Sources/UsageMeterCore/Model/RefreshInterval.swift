import Foundation

/// How often to poll. User-selectable because the shortest useful feedback loop and
/// the cost of repeatedly asking a local provider CLI are product trade-offs.
public enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800
    case oneHour = 3600

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    /// Ten minutes is frequent compared with the shortest displayed usage window and
    /// avoids spending work on nearly identical readings. Claude may return its own
    /// cached figure, while Codex normally receives App Server notifications and uses
    /// polling as insurance.
    public static let recommended = RefreshInterval.tenMinutes

    /// Kept provider-specific even though both now say ten minutes: Codex also receives
    /// push updates and polls only as insurance, while Claude depends entirely on
    /// polling. The reasons differ, so the values are allowed to diverge again.
    public static func recommended(for provider: ProviderKind) -> RefreshInterval {
        switch provider {
        case .claude: .tenMinutes
        case .codex: .tenMinutes
        }
    }

    public var displayName: String {
        displayName(locale: Locale(identifier: "en_US"))
    }

    public func displayName(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return switch self {
            case .oneMinute: "1 分鐘"
            case .threeMinutes: "3 分鐘"
            case .fiveMinutes: "5 分鐘"
            case .tenMinutes: "10 分鐘"
            case .thirtyMinutes: "30 分鐘"
            case .oneHour: "60 分鐘"
            }
        }
        return switch self {
        case .oneMinute: "1 minute"
        case .threeMinutes: "3 minutes"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "60 minutes"
        }
    }

    /// Roughly how many requests a day this interval produces. Shown for every option,
    /// because the number is the argument — it makes the trade-off concrete without
    /// anyone having to do arithmetic in their head.
    public var requestsPerDay: Int { Int((24 * 60 * 60) / seconds) }

    /// Shown next to the choice rather than blocking it. It is the user's account.
    public var caution: String? {
        caution(locale: Locale(identifier: "en_US"))
    }

    public func caution(locale: Locale) -> String? {
        switch self {
        case .oneMinute, .threeMinutes:
            TimeFormatting.usesTraditionalChinese(locale)
                ? "頻繁查詢通常只會拿到相同或快取的讀數，不一定更即時。"
                : "Frequent checks usually return the same or cached reading and may not be fresher."
        default:
            nil
        }
    }

    public func isRecommended(for provider: ProviderKind) -> Bool {
        self == Self.recommended(for: provider)
    }
}
