import Foundation

/// The state semantics both providers must share.
///
/// Shared deliberately: two gauges sitting side by side in one menu bar cannot mean
/// different things by the same appearance.
///
/// `throttled` is separate from `stale` on purpose: being rate limited has a known
/// recovery time, and telling the user "unknown error" when the app knows exactly
/// when it will recover is a worse answer than telling them the time.
public enum UsageDisplayState: Sendable, Hashable {
    case starting
    case refreshing(previous: UsageSnapshot?)
    case current(UsageSnapshot)
    case stale(UsageSnapshot, reason: UsageError)
    case throttled(previous: UsageSnapshot?, until: Date)
    case unavailable(UsageError)

    /// The most recent trustworthy reading, whatever the current state.
    /// Never synthesised — a state with no reading returns `nil` rather than 0%.
    public var snapshot: UsageSnapshot? {
        switch self {
        case .starting, .unavailable: nil
        case .refreshing(let previous): previous
        case .current(let snapshot): snapshot
        case .stale(let snapshot, _): snapshot
        case .throttled(let previous, _): previous
        }
    }

    /// Whether the displayed numbers are known to be out of date.
    public var isDataTrustworthyAsCurrent: Bool {
        switch self {
        case .current: true
        case .refreshing(let previous): previous != nil
        case .starting, .stale, .throttled, .unavailable: false
        }
    }

    public var error: UsageError? {
        switch self {
        case .stale(_, let reason): reason
        case .unavailable(let error): error
        case .throttled(_, let until): .rateLimited(retryAfter: until)
        case .starting, .refreshing, .current: nil
        }
    }

    public var statusLabel: String {
        statusLabel(locale: Locale(identifier: "en_US"))
    }

    public func statusLabel(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return switch self {
            case .starting: "啟動中"
            case .refreshing(let previous): previous == nil ? "查詢中" : "更新中"
            case .current: "最新"
            case .stale: "過期"
            case .throttled: "限流中"
            case .unavailable: "不可用"
            }
        }
        return switch self {
        case .starting: "Starting"
        case .refreshing(let previous): previous == nil ? "Fetching" : "Refreshing"
        case .current: "Current"
        case .stale: "Stale"
        case .throttled: "Rate limited"
        case .unavailable: "Unavailable"
        }
    }

    /// Maps a failure onto the right state given whatever reading survives.
    ///
    /// One place decides this so the rule "keep the old reading but say it is old,
    /// and never turn unknown into 0%" cannot drift between call sites.
    public static func afterFailure(_ error: UsageError, previous: UsageSnapshot?) -> UsageDisplayState {
        if case .rateLimited(let retryAfter) = error {
            return .throttled(previous: previous, until: retryAfter ?? Date().addingTimeInterval(BackoffPolicy.claude.cap))
        }
        if let previous { return .stale(previous, reason: error) }
        return .unavailable(error)
    }
}
