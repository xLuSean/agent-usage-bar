import Foundation

/// A deliberately closed description of a provider failure.
///
/// Associated strings on `UsageError` can contain paths, Foundation diagnostics, or
/// provider-controlled material. None of them crosses this boundary: the persisted log
/// stores only one of these app-authored categories.
public enum DiagnosticErrorKind: String, Codable, CaseIterable, Sendable, Hashable {
    case rateLimited
    case offline
    case schemaChanged
    case transport
    case notImplemented
    case claudeExecutableNotFound
    case claudeExecutableInvalid
    case claudeNotSignedIn
    case claudeVersionUnsupported
    case claudeCommandFailed
    case claudeCommandTimedOut
    case claudeUsageOutdated
    case codexExecutableNotFound
    case codexExecutableInvalid
    case codexNotLoggedIn
    case codexVersionIncompatible
    case codexRequestTimedOut
    case codexAppServerUnavailable

    public init(_ error: UsageError) {
        self = switch error {
        case .rateLimited: .rateLimited
        case .offline: .offline
        case .schemaChanged: .schemaChanged
        case .transport: .transport
        case .notImplemented: .notImplemented
        case .claudeExecutableNotFound: .claudeExecutableNotFound
        case .claudeExecutableInvalid: .claudeExecutableInvalid
        case .claudeNotSignedIn: .claudeNotSignedIn
        case .claudeVersionUnsupported: .claudeVersionUnsupported
        case .claudeCommandFailed: .claudeCommandFailed
        case .claudeCommandTimedOut: .claudeCommandTimedOut
        case .claudeUsageOutdated: .claudeUsageOutdated
        case .codexExecutableNotFound: .codexExecutableNotFound
        case .codexExecutableInvalid: .codexExecutableInvalid
        case .codexNotLoggedIn: .codexNotLoggedIn
        case .codexVersionIncompatible: .codexVersionIncompatible
        case .codexRequestTimedOut: .codexRequestTimedOut
        case .codexAppServerUnavailable: .codexAppServerUnavailable
        }
    }

    public func displayName(locale: Locale) -> String {
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        return switch self {
        case .rateLimited: chinese ? "已被限流（429）" : "Rate limited (429)"
        case .offline: chinese ? "網路不可用" : "Network unavailable"
        case .schemaChanged: chinese ? "回應格式已改變" : "Response format changed"
        case .transport: chinese ? "連線失敗" : "Connection failed"
        case .notImplemented: chinese ? "尚未實作" : "Not implemented"
        case .claudeExecutableNotFound: chinese ? "找不到 Claude Code CLI" : "Claude Code CLI not found"
        case .claudeExecutableInvalid: chinese ? "Claude CLI 路徑不可用" : "Claude CLI path unavailable"
        case .claudeNotSignedIn: chinese ? "尚未登入 Claude Code" : "Not signed in to Claude Code"
        case .claudeVersionUnsupported: chinese ? "Claude Code 版本不支援額度查詢" : "Claude Code is too old to report usage"
        case .claudeCommandFailed: chinese ? "Claude Code 查詢失敗" : "Claude Code usage query failed"
        case .claudeCommandTimedOut: chinese ? "Claude Code 查詢逾時" : "Claude Code usage query timed out"
        case .claudeUsageOutdated: chinese ? "額度資料已跨過重置時間" : "Usage reading is past its reset time"
        case .codexExecutableNotFound: chinese ? "找不到 Codex CLI" : "Codex CLI not found"
        case .codexExecutableInvalid: chinese ? "Codex CLI 路徑不可用" : "Codex CLI path unavailable"
        case .codexNotLoggedIn: chinese ? "尚未登入 Codex" : "Not signed in to Codex"
        case .codexVersionIncompatible: chinese ? "Codex CLI 版本不相容" : "Codex CLI version incompatible"
        case .codexRequestTimedOut: chinese ? "Codex App Server 回應逾時" : "Codex App Server timed out"
        case .codexAppServerUnavailable: chinese ? "Codex App Server 無法使用" : "Codex App Server unavailable"
        }
    }
}

public enum DiagnosticRetentionPeriod: Int, Codable, CaseIterable, Sendable, Identifiable {
    case threeDays = 3
    case fiveDays = 5
    case sevenDays = 7

    public var id: Int { rawValue }
}

public struct DiagnosticLogEntry: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let occurredAt: Date
    public let provider: ProviderKind
    public let kind: DiagnosticErrorKind

    public init(id: UUID = UUID(), occurredAt: Date, provider: ProviderKind, kind: DiagnosticErrorKind) {
        self.id = id
        self.occurredAt = occurredAt
        self.provider = provider
        self.kind = kind
    }
}

/// Persists a bounded, privacy-safe history of failed usage queries.
///
/// This is not a raw diagnostic log. It accepts `UsageError` only at append time and
/// immediately reduces it to `DiagnosticErrorKind`, discarding every associated value.
public struct DiagnosticLogStore {
    public static let maximumEntries = 200

    private static let entriesKey = "v1.diagnosticLog"
    private static let retentionKey = "v1.diagnosticRetentionDays"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadRetention() -> DiagnosticRetentionPeriod {
        let raw = defaults.object(forKey: Self.retentionKey) as? Int
        return raw.flatMap(DiagnosticRetentionPeriod.init(rawValue:)) ?? .fiveDays
    }

    @discardableResult
    public func saveRetention(
        _ retention: DiagnosticRetentionPeriod,
        now: Date = Date()
    ) -> [DiagnosticLogEntry] {
        defaults.set(retention.rawValue, forKey: Self.retentionKey)
        return load(now: now, retention: retention)
    }

    public func load(
        now: Date = Date(),
        retention: DiagnosticRetentionPeriod? = nil
    ) -> [DiagnosticLogEntry] {
        let selectedRetention = retention ?? loadRetention()
        guard let data = defaults.data(forKey: Self.entriesKey),
              let decoded = try? JSONDecoder().decode([DiagnosticLogEntry].self, from: data) else {
            if defaults.object(forKey: Self.entriesKey) != nil {
                defaults.removeObject(forKey: Self.entriesKey)
            }
            return []
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(selectedRetention.rawValue * 86_400))
        let retained = decoded
            .filter { $0.occurredAt >= cutoff && $0.occurredAt <= now }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(Self.maximumEntries)
        let result = Array(retained)
        if result != decoded {
            persist(result)
        }
        return result
    }

    @discardableResult
    public func append(
        provider: ProviderKind,
        error: UsageError,
        now: Date = Date()
    ) -> [DiagnosticLogEntry] {
        var entries = load(now: now)
        entries.insert(
            DiagnosticLogEntry(occurredAt: now, provider: provider, kind: DiagnosticErrorKind(error)),
            at: 0
        )
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        persist(entries)
        return entries
    }

    public func clear() {
        defaults.removeObject(forKey: Self.entriesKey)
    }

    private func persist(_ entries: [DiagnosticLogEntry]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.entriesKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }
}
