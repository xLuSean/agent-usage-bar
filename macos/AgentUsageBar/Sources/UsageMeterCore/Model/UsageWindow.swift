import Foundation

/// One limit window: the 5-hour session window, the 7-day window, or a
/// per-model weekly window.
public struct UsageWindow: Sendable, Hashable, Identifiable, Codable {

    public enum Kind: Sendable, Hashable, Codable {
        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        case session
        case weeklyAll
        case weeklyScoped
        /// A `kind` this build has never seen. Displayed, not discarded.
        case unrecognized(String)

        public init(rawValue: String) {
            switch rawValue {
            case "session": self = .session
            case "weekly_all": self = .weeklyAll
            case "weekly_scoped": self = .weeklyScoped
            default: self = .unrecognized(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .session: "session"
            case .weeklyAll: "weekly_all"
            case .weeklyScoped: "weekly_scoped"
            case .unrecognized(let raw): raw
            }
        }
    }

    public enum Group: Sendable, Hashable, Codable {
        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        case session
        case weekly
        case unrecognized(String)

        public init(rawValue: String) {
            switch rawValue {
            case "session": self = .session
            case "weekly": self = .weekly
            default: self = .unrecognized(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .session: "session"
            case .weekly: "weekly"
            case .unrecognized(let raw): raw
            }
        }
    }

    public let kind: Kind
    public let group: Group
    public let used: UsedPercent
    public let resetsAt: Date?
    /// Whether this is the limit currently binding the account.
    public let isActive: Bool
    /// `scope.model.display_name` for `weekly_scoped` windows.
    public let modelDisplayName: String?
    /// Provider-supplied window length. `nil` keeps the established Claude labels.
    public let durationMinutes: Int?

    public init(
        kind: Kind,
        group: Group,
        used: UsedPercent,
        resetsAt: Date?,
        isActive: Bool,
        modelDisplayName: String? = nil,
        durationMinutes: Int? = nil
    ) {
        self.kind = kind
        self.group = group
        self.used = used
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.modelDisplayName = modelDisplayName
        self.durationMinutes = durationMinutes
    }

    /// Stable identity built from kind and model, never from array position.
    public var id: String {
        if let modelDisplayName { "\(kind.rawValue)#\(modelDisplayName)" } else { kind.rawValue }
    }

    public var displayName: String {
        displayName(locale: Locale(identifier: "en_US"))
    }

    public func displayName(locale: Locale) -> String {
        let isChinese = TimeFormatting.usesTraditionalChinese(locale)
        if let durationMinutes {
            let duration: String
            if durationMinutes < 60 {
                duration = isChinese
                    ? "\(durationMinutes) 分鐘"
                    : "\(durationMinutes) \(durationMinutes == 1 ? "minute" : "minutes")"
            } else if durationMinutes.isMultiple(of: 60 * 24) {
                let days = durationMinutes / (60 * 24)
                duration = isChinese ? "\(days) 天" : "\(days) \(days == 1 ? "day" : "days")"
            } else if durationMinutes.isMultiple(of: 60) {
                let hours = durationMinutes / 60
                duration = isChinese ? "\(hours) 小時" : "\(hours) \(hours == 1 ? "hour" : "hours")"
            } else {
                duration = isChinese ? "\(durationMinutes) 分鐘" : "\(durationMinutes) minutes"
            }
            if case .weeklyScoped = kind, let modelDisplayName {
                return "\(duration) · \(modelDisplayName)"
            }
            return duration
        }
        if isChinese {
            return switch kind {
            case .session: "5 小時"
            case .weeklyAll: "7 天"
            case .weeklyScoped: modelDisplayName.map { "7 天 · \($0)" } ?? "7 天 · 依模型"
            case .unrecognized(let raw): raw
            }
        }
        return switch kind {
        case .session: "5 hours"
        case .weeklyAll: "7 days"
        case .weeklyScoped: modelDisplayName.map { "7 days · \($0)" } ?? "7 days · per model"
        case .unrecognized(let raw): raw
        }
    }
}
