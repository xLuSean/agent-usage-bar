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

    fileprivate func detailDescription(locale: Locale) -> String {
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        return switch self {
        case .rateLimited:
            chinese ? "資料來源拒絕了這次查詢，App 會依退避時間再試。" :
                "The provider rejected this query. The app will retry after its backoff period."
        case .offline:
            chinese ? "查詢時無法使用網路連線。" : "The network connection was unavailable during this query."
        case .schemaChanged:
            chinese ? "App 無法辨識資料來源回傳的用量結構。" :
                "The app could not recognize the usage structure returned by the provider."
        case .transport:
            chinese ? "查詢未能完成與資料來源的連線。" : "The query could not complete its connection to the provider."
        case .notImplemented:
            chinese ? "這個資料來源尚未提供用量查詢。" : "This provider does not yet support usage queries."
        case .claudeExecutableNotFound:
            chinese ? "App 找不到 Claude Code CLI。" : "The app could not find the Claude Code CLI."
        case .claudeExecutableInvalid:
            chinese ? "設定的 Claude Code CLI 不是可執行的一般檔案。" :
                "The configured Claude Code CLI is not an executable regular file."
        case .claudeNotSignedIn:
            chinese ? "Claude Code 回報目前沒有可使用的登入狀態。" :
                "Claude Code reported that no usable sign-in state was available."
        case .claudeVersionUnsupported:
            chinese ? "目前的 Claude Code 版本不接受 App 使用的唯讀查詢。" :
                "This Claude Code version did not accept the read-only query used by the app."
        case .claudeCommandFailed:
            chinese ? "Claude Code 的唯讀用量指令沒有成功完成。" :
                "Claude Code's read-only usage command did not complete successfully."
        case .claudeCommandTimedOut:
            chinese ? "Claude Code 的唯讀用量指令在期限內沒有完成。" :
                "Claude Code's read-only usage command did not finish before the deadline."
        case .claudeUsageOutdated:
            chinese ? "Claude Code 回傳的快取資料已跨過其中一個重置時間。" :
                "Claude Code returned cached data that had passed one of its reset times."
        case .codexExecutableNotFound:
            chinese ? "App 找不到 Codex CLI。" : "The app could not find the Codex CLI."
        case .codexExecutableInvalid:
            chinese ? "設定的 Codex CLI 不是可執行的一般檔案。" :
                "The configured Codex CLI is not an executable regular file."
        case .codexNotLoggedIn:
            chinese ? "Codex App Server 回報目前沒有登入。" : "Codex App Server reported that no account was signed in."
        case .codexVersionIncompatible:
            chinese ? "目前的 Codex App Server 不支援 App 使用的唯讀查詢。" :
                "This Codex App Server does not support the read-only query used by the app."
        case .codexRequestTimedOut:
            chinese ? "Codex App Server 沒有在期限內回覆唯讀查詢。" :
                "Codex App Server did not answer the read-only query before the deadline."
        case .codexAppServerUnavailable:
            chinese ? "Codex App Server 無法啟動、連線或繼續提供服務。" :
                "Codex App Server could not start, connect, or continue serving requests."
        }
    }
}

/// A closed, app-authored explanation of a diagnostic failure.
///
/// The raw associated strings on `UsageError` are deliberately not persisted. They can
/// contain provider-controlled text, paths, Foundation diagnostics, or credential-like
/// material. Known shapes are reduced to these stable reasons; everything else becomes
/// `unrecognizedResponse` without retaining the source text.
public enum DiagnosticErrorDetail: String, Codable, Sendable, Hashable {
    case categorySummary
    case unrecognizedResponse
    case claudeOutputNotJSONObject
    case claudeCLIReportedUsageError
    case claudeCLIResultNotSuccessful
    case claudeResultTextMissing
    case claudeSessionLineMissing
    case claudeSessionLineUnreadable
    case claudeSessionLineDuplicated
    case claudeSessionPercentageInvalid
    case claudeSessionResetInvalid
    case claudeSessionResetMissing
    case claudeWeeklyLineMissing
    case claudeWeeklyLineUnreadable
    case claudeWeeklyLineDuplicated
    case claudeWeeklyPercentageInvalid
    case claudeWeeklyResetInvalid
    case claudeWeeklyResetMissing
    case claudeCommandExitedNonzero
    case codexResponseNotJSONObject
    case codexRateLimitsMissing
    case codexWindowsMissing
    case codexUsedPercentInvalid
    case codexWindowDurationInvalid
    case codexResetTimeInvalid
    case codexMessageTooLarge

    public init(provider: ProviderKind, error: UsageError) {
        switch error {
        case .schemaChanged(let rawDetail):
            self = Self.schemaDetail(provider: provider, rawDetail: rawDetail)
        case .claudeCommandFailed(let rawDetail):
            if rawDetail == "The CLI reported is_error for /usage" {
                self = .claudeCLIReportedUsageError
            } else if rawDetail == "The CLI did not report subtype=success for /usage" {
                self = .claudeCLIResultNotSuccessful
            } else if rawDetail.hasPrefix("Claude Code exited with status ") {
                self = .claudeCommandExitedNonzero
            } else {
                self = .categorySummary
            }
        default:
            self = .categorySummary
        }
    }

    public func displayName(kind: DiagnosticErrorKind, locale: Locale) -> String {
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        return switch self {
        case .categorySummary:
            kind.detailDescription(locale: locale)
        case .unrecognizedResponse:
            chinese ? "App 無法辨識回應，但為保護隱私，未保存資料來源的原始文字。" :
                "The app could not recognize the response. The provider's raw text was not saved for privacy."
        case .claudeOutputNotJSONObject:
            chinese ? "Claude Code 的輸出不是 App 預期的 JSON 物件。" :
                "Claude Code's output was not the JSON object expected by the app."
        case .claudeCLIReportedUsageError:
            chinese ? "Claude Code 的 JSON 外層明確將 `/usage` 標記為錯誤。" :
                "Claude Code's JSON envelope explicitly marked `/usage` as an error."
        case .claudeCLIResultNotSuccessful:
            chinese ? "Claude Code 的 JSON 外層沒有將 `/usage` 標記為成功。" :
                "Claude Code's JSON envelope did not mark `/usage` as successful."
        case .claudeResultTextMissing:
            chinese ? "Claude Code 的 JSON 外層存在，但缺少可解析的 `result` 文字。" :
                "Claude Code returned a JSON envelope without parsable `result` text."
        case .claudeSessionLineMissing:
            chinese ? "Claude Code 沒有回傳 Current session 用量行。" :
                "Claude Code did not return the Current session usage line."
        case .claudeSessionLineUnreadable:
            chinese ? "Claude Code 回傳了 Current session 用量行，但 App 無法解析它。" :
                "Claude Code returned a Current session usage line that the app could not parse."
        case .claudeSessionLineDuplicated:
            chinese ? "Claude Code 回傳了不只一行 Current session 用量，App 無法安全選擇。" :
                "Claude Code returned more than one Current session usage line, so the app could not safely choose one."
        case .claudeSessionPercentageInvalid:
            chinese ? "Claude Code 回傳的 Current session 百分比不是有效的 0 到 100 整數。" :
                "Claude Code returned an invalid Current session percentage."
        case .claudeSessionResetInvalid:
            chinese ? "Claude Code 回傳的 Current session 重置時間無法解析。" :
                "Claude Code returned an unreadable Current session reset time."
        case .claudeSessionResetMissing:
            chinese ? "Claude Code 回傳非零的 Current session 用量，但沒有重置時間。" :
                "Claude Code returned nonzero Current session usage without a reset time."
        case .claudeWeeklyLineMissing:
            chinese ? "Claude Code 沒有回傳 Current week (all models) 用量行。" :
                "Claude Code did not return the Current week (all models) usage line."
        case .claudeWeeklyLineUnreadable:
            chinese ? "Claude Code 回傳了 Current week (all models) 用量行，但 App 無法解析它。" :
                "Claude Code returned a Current week (all models) usage line that the app could not parse."
        case .claudeWeeklyLineDuplicated:
            chinese ? "Claude Code 回傳了不只一行 Current week (all models) 用量，App 無法安全選擇。" :
                "Claude Code returned more than one Current week (all models) usage line, so the app could not safely choose one."
        case .claudeWeeklyPercentageInvalid:
            chinese ? "Claude Code 回傳的 Current week (all models) 百分比不是有效的 0 到 100 整數。" :
                "Claude Code returned an invalid Current week (all models) percentage."
        case .claudeWeeklyResetInvalid:
            chinese ? "Claude Code 回傳的 Current week (all models) 重置時間無法解析。" :
                "Claude Code returned an unreadable Current week (all models) reset time."
        case .claudeWeeklyResetMissing:
            chinese ? "Claude Code 回傳 Current week (all models) 用量，但沒有必要的重置時間。" :
                "Claude Code returned Current week (all models) usage without its required reset time."
        case .claudeCommandExitedNonzero:
            chinese ? "Claude Code 的唯讀用量指令以非零狀態結束。" :
                "Claude Code's read-only usage command exited with a nonzero status."
        case .codexResponseNotJSONObject:
            chinese ? "Codex App Server 的 rate-limit 回應不是 JSON 物件。" :
                "Codex App Server's rate-limit response was not a JSON object."
        case .codexRateLimitsMissing:
            chinese ? "Codex App Server 的回應缺少一般 codex rateLimits。" :
                "Codex App Server's response did not include the standard codex rateLimits."
        case .codexWindowsMissing:
            chinese ? "Codex rateLimits 沒有可解析的 primary 或 secondary 時間窗。" :
                "Codex rateLimits did not contain a parsable primary or secondary window."
        case .codexUsedPercentInvalid:
            chinese ? "Codex 回傳的 usedPercent 不是有效的 0 到 100 整數。" :
                "Codex returned a usedPercent that was not an integer from 0 through 100."
        case .codexWindowDurationInvalid:
            chinese ? "Codex 回傳的 windowDurationMins 不是整數或 null。" :
                "Codex returned a windowDurationMins value that was not an integer or null."
        case .codexResetTimeInvalid:
            chinese ? "Codex 回傳的 resetsAt 不是整數或 null。" :
                "Codex returned a resetsAt value that was not an integer or null."
        case .codexMessageTooLarge:
            chinese ? "Codex App Server 傳來超過 4 MB 且沒有換行的資料。" :
                "Codex App Server sent more than 4 MB without a newline."
        }
    }

    private static func schemaDetail(provider: ProviderKind, rawDetail: String) -> Self {
        switch provider {
        case .claude:
            if rawDetail == "Command output is not a JSON object" { return .claudeOutputNotJSONObject }
            if rawDetail == "Missing result text" { return .claudeResultTextMissing }
            if matchesLineDetail(rawDetail, label: "Current session", kind: "missing") { return .claudeSessionLineMissing }
            if matchesLineDetail(rawDetail, label: "Current session", kind: "unreadable") { return .claudeSessionLineUnreadable }
            if matchesLineDetail(rawDetail, label: "Current session", kind: "duplicated") { return .claudeSessionLineDuplicated }
            if matchesLineDetail(rawDetail, label: "Current session", kind: "percentage") { return .claudeSessionPercentageInvalid }
            if matchesLineDetail(rawDetail, label: "Current session", kind: "resetInvalid") { return .claudeSessionResetInvalid }
            if matchesLineDetail(rawDetail, label: "Current session", kind: "resetMissing") { return .claudeSessionResetMissing }
            if matchesLineDetail(rawDetail, label: "Current week (all models)", kind: "missing") { return .claudeWeeklyLineMissing }
            if matchesLineDetail(rawDetail, label: "Current week (all models)", kind: "unreadable") { return .claudeWeeklyLineUnreadable }
            if matchesLineDetail(rawDetail, label: "Current week (all models)", kind: "duplicated") { return .claudeWeeklyLineDuplicated }
            if matchesLineDetail(rawDetail, label: "Current week (all models)", kind: "percentage") { return .claudeWeeklyPercentageInvalid }
            if matchesLineDetail(rawDetail, label: "Current week (all models)", kind: "resetInvalid") { return .claudeWeeklyResetInvalid }
            if matchesLineDetail(rawDetail, label: "Current week (all models)", kind: "resetMissing") { return .claudeWeeklyResetMissing }
        case .codex:
            if rawDetail == "Codex rate-limit response is not a JSON object" { return .codexResponseNotJSONObject }
            if rawDetail == "Missing standard codex rateLimits" { return .codexRateLimitsMissing }
            if rawDetail == "Standard codex rateLimits has no decodable primary or secondary window" { return .codexWindowsMissing }
            if rawDetail == "Codex usedPercent must be an integer from 0 through 100" { return .codexUsedPercentInvalid }
            if rawDetail == "Codex windowDurationMins must be an integer or null" { return .codexWindowDurationInvalid }
            if rawDetail == "Codex resetsAt must be an integer or null" { return .codexResetTimeInvalid }
            if rawDetail == "Codex App Server sent more than 4 MB without a newline" { return .codexMessageTooLarge }
        }
        return .unrecognizedResponse
    }

    private static func matchesLineDetail(_ detail: String, label: String, kind: String) -> Bool {
        switch kind {
        case "missing":
            return detail == "Missing the \"\(label)\" line"
        case "unreadable":
            return detail == "Unreadable \"\(label)\" line"
        case "duplicated":
            return detail.hasPrefix("Found ") && detail.hasSuffix(" \"\(label)\" lines")
        case "percentage":
            return detail == "Unreadable percentage in \"\(label)\"" ||
                (detail.hasPrefix("Percentage ") && detail.hasSuffix(" is out of range in \"\(label)\""))
        case "resetInvalid":
            return detail == "Unreadable reset time in \"\(label)\""
        case "resetMissing":
            return detail == "Missing reset time in \"\(label)\"" ||
                detail == "Missing reset time for nonzero \"\(label)\""
        default:
            return false
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
    public let detail: DiagnosticErrorDetail?

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        provider: ProviderKind,
        kind: DiagnosticErrorKind,
        detail: DiagnosticErrorDetail? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.provider = provider
        self.kind = kind
        self.detail = detail
    }

    public func detailMessage(locale: Locale) -> String {
        guard let detail else {
            return TimeFormatting.usesTraditionalChinese(locale) ?
                "這筆舊版紀錄沒有保存更多診斷細節。" :
                "This older log entry did not save additional diagnostic detail."
        }
        return detail.displayName(kind: kind, locale: locale)
    }

    public func copyText(locale: Locale) -> String {
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        let providerLabel = chinese ? "資料來源" : "Provider"
        let timeLabel = chinese ? "時間" : "Time"
        let errorLabel = chinese ? "錯誤" : "Error"
        let detailLabel = chinese ? "詳細訊息" : "Detail"
        return [
            "\(providerLabel): \(provider.displayName)",
            "\(timeLabel): \(TimeFormatting.dateAndTime(occurredAt, locale: locale))",
            "\(errorLabel): \(kind.displayName(locale: locale))",
            "\(detailLabel): \(detailMessage(locale: locale))",
        ].joined(separator: "\n")
    }
}

/// Persists a bounded, privacy-safe history of failed usage queries.
///
/// This is not a raw diagnostic log. It accepts `UsageError` only at append time and
/// immediately reduces it to `DiagnosticErrorKind`, discarding every associated value.
public struct DiagnosticLogStore {
    public static let maximumEntries = 200
    static let maximumStoredBytes = 65_536

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
              data.count <= Self.maximumStoredBytes,
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
            DiagnosticLogEntry(
                occurredAt: now,
                provider: provider,
                kind: DiagnosticErrorKind(error),
                detail: DiagnosticErrorDetail(provider: provider, error: error)
            ),
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
        guard data.count <= Self.maximumStoredBytes else {
            defaults.removeObject(forKey: Self.entriesKey)
            return
        }
        defaults.set(data, forKey: Self.entriesKey)
    }
}
