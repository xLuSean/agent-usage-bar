import Foundation

/// Failure modes that need distinct user-facing explanations.
///
/// `rateLimited` and `claudeUsageOutdated` exist separately because collapsing either
/// into a generic error loses the only actionable part of the message.
///
/// The Claude cases changed shape in 0.3.0. The app no longer reads the OAuth
/// credential itself, so keychain, scope, and expiry failures are no longer its to
/// report — Claude Code handles its own sign-in and the app only has to say when the
/// command could not answer. The old set is recorded in `docs/LEGACY_KEYCHAIN_PATH.md`.
public enum UsageError: Error, Sendable, Hashable {
    /// HTTP 429 or an upstream rate-limit report. `retryAfter` is upstream's own answer
    /// when it gave one.
    case rateLimited(retryAfter: Date?)
    case offline
    /// Response parsed but did not contain what this build needs.
    case schemaChanged(String)
    case transport(String)
    /// This provider has no implementation yet. Not a fault, and not worth retrying.
    case notImplemented(String)

    /// Claude-specific failures. All of them describe the local CLI, not an account.
    case claudeExecutableNotFound
    case claudeExecutableInvalid(String)
    case claudeNotSignedIn
    case claudeVersionUnsupported(String)
    case claudeCommandFailed(String)
    case claudeCommandTimedOut
    /// `/usage` answered from Claude Code's local cache with a reading whose window has
    /// already rolled over. The figure describes a window that has ended, so the current
    /// usage is unknown — and unknown is never drawn as 0%.
    case claudeUsageOutdated(resetsAt: Date)

    /// Codex-specific failures stay distinct so the UI can offer the right next step.
    case codexExecutableNotFound
    case codexExecutableInvalid(String)
    case codexNotLoggedIn
    case codexVersionIncompatible(String)
    case codexRequestTimedOut(String)
    case codexAppServerUnavailable(String)

    public var isThrottling: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    /// A known gap rather than something that went wrong. Presented neutrally and never
    /// retried: a provider with no implementation will not start working on the next
    /// attempt, so counting failures against it is noise dressed up as diagnostics.
    public var isExpectedLimitation: Bool {
        switch self {
        case .notImplemented: true
        default: false
        }
    }

    public var shortDescription: String {
        shortDescription(locale: Locale(identifier: "en_US"))
    }

    public func shortDescription(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return switch self {
            case .rateLimited: "已被限流（429）"
            case .offline: "網路不可用"
            case .schemaChanged: "回應格式已改變"
            case .transport: "連線失敗"
            case .notImplemented: "尚未實作"
            case .claudeExecutableNotFound: "找不到 Claude Code CLI"
            case .claudeExecutableInvalid: "Claude CLI 路徑不可用"
            case .claudeNotSignedIn: "尚未登入 Claude Code"
            case .claudeVersionUnsupported: "Claude Code 版本不支援額度查詢"
            case .claudeCommandFailed: "Claude Code 查詢失敗"
            case .claudeCommandTimedOut: "Claude Code 查詢逾時"
            case .claudeUsageOutdated: "額度資料已跨過重置時間"
            case .codexExecutableNotFound: "找不到 Codex CLI"
            case .codexExecutableInvalid: "Codex CLI 路徑不可用"
            case .codexNotLoggedIn: "尚未登入 Codex"
            case .codexVersionIncompatible: "Codex CLI 版本不相容"
            case .codexRequestTimedOut: "Codex App Server 回應逾時"
            case .codexAppServerUnavailable: "Codex App Server 無法使用"
            }
        }
        return switch self {
        case .rateLimited: "Rate limited (429)"
        case .offline: "Network unavailable"
        case .schemaChanged: "Response format changed"
        case .transport: "Connection failed"
        case .notImplemented: "Not implemented"
        case .claudeExecutableNotFound: "Claude Code CLI not found"
        case .claudeExecutableInvalid: "Claude CLI path unavailable"
        case .claudeNotSignedIn: "Not signed in to Claude Code"
        case .claudeVersionUnsupported: "Claude Code is too old to report usage"
        case .claudeCommandFailed: "Claude Code usage query failed"
        case .claudeCommandTimedOut: "Claude Code usage query timed out"
        case .claudeUsageOutdated: "Usage reading is past its reset time"
        case .codexExecutableNotFound: "Codex CLI not found"
        case .codexExecutableInvalid: "Codex CLI path unavailable"
        case .codexNotLoggedIn: "Not signed in to Codex"
        case .codexVersionIncompatible: "Codex CLI version incompatible"
        case .codexRequestTimedOut: "Codex App Server timed out"
        case .codexAppServerUnavailable: "Codex App Server unavailable"
        }
    }

    /// What the user can actually do about it. Empty when there is nothing.
    public var remedy: String? {
        remedy(locale: Locale(identifier: "en_US"))
    }

    public func remedy(locale: Locale) -> String? {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return switch self {
            case .rateLimited: "此端點以帳號計算限流，退避期間請勿手動重試。"
            case .offline: "檢查網路連線。"
            case .schemaChanged(let detail):
                "資料來源的用量回應格式可能已改變：\(Self.localizedDetail(detail))"
            case .transport(let detail): Self.localizedDetail(detail)
            case .notImplemented(let detail): Self.localizedDetail(detail)
            case .claudeExecutableNotFound:
                "請安裝 Claude Code，或在設定的「資料來源」頁指定 claude 執行檔路徑。"
            case .claudeExecutableInvalid(let path):
                "指定的路徑不是可執行的一般檔案：\(path)"
            case .claudeNotSignedIn:
                "請在終端機執行 `claude` 啟動 Claude Code；若出現提示，再完成登入，然後回來按「重新整理」。本 App 只會執行唯讀的 /usage 查詢，不會替你執行登入。"
            case .claudeVersionUnsupported(let detail):
                "目前的 Claude Code 不支援這個查詢方式，請更新 Claude Code。\(Self.localizedDetail(detail))"
            case .claudeCommandFailed(let detail): Self.localizedDetail(detail)
            case .claudeCommandTimedOut:
                "唯讀的 /usage 查詢未在期限內完成；App 會依退避策略重試。"
            case .claudeUsageOutdated:
                "Claude Code 回報的是本機快取，而該筆讀數的時間窗已經結束。請確認網路連線後按「重新整理」；若持續發生，在終端機執行一次 `claude`。"
            case .codexExecutableNotFound:
                "請安裝 Codex CLI，或在設定的「資料來源」頁指定 codex 執行檔路徑。"
            case .codexExecutableInvalid(let path):
                "指定的路徑不是可執行的一般檔案：\(path)"
            case .codexNotLoggedIn:
                "請先在 Codex CLI 或 Codex App 完成登入，再按「重新整理」。本 App 不會自行啟動登入流程。"
            case .codexVersionIncompatible(let detail):
                "目前的 Codex App Server 不支援額度查詢，請更新 Codex CLI。\(Self.localizedDetail(detail))"
            case .codexRequestTimedOut(let method):
                "唯讀查詢 \(method) 未在期限內完成；App 會依退避策略重試。"
            case .codexAppServerUnavailable(let detail): Self.localizedDetail(detail)
            }
        }
        return switch self {
        case .rateLimited: "Rate limits apply per account. Do not retry manually during backoff."
        case .offline: "Check your network connection."
        case .schemaChanged(let detail): "The provider's usage response format may have changed: \(detail)"
        case .transport(let detail): detail
        case .notImplemented(let detail): detail
        case .claudeExecutableNotFound:
            "Install Claude Code, or specify the claude executable in Settings > Data Sources."
        case .claudeExecutableInvalid(let path):
            "The selected path is not an executable regular file: \(path)"
        case .claudeNotSignedIn:
            "Run `claude` in Terminal to launch Claude Code. Sign in if prompted, then return and click Refresh. This app only runs the read-only /usage query; it never signs in for you."
        case .claudeVersionUnsupported(let detail):
            "This Claude Code build does not support the query this app uses. Update Claude Code. \(detail)"
        case .claudeCommandFailed(let detail): detail
        case .claudeCommandTimedOut:
            "The read-only /usage query timed out. The app will retry according to its backoff policy."
        case .claudeUsageOutdated:
            "Claude Code answered from its local cache and that reading's window has already ended. Check your connection and click Refresh; if it persists, run `claude` once in Terminal."
        case .codexExecutableNotFound:
            "Install Codex CLI, or specify the codex executable in Settings > Data Sources."
        case .codexExecutableInvalid(let path):
            "The selected path is not an executable regular file: \(path)"
        case .codexNotLoggedIn:
            "Sign in with Codex CLI or the Codex app, then click Refresh. This app never starts a sign-in flow."
        case .codexVersionIncompatible(let detail):
            "This Codex App Server does not support usage-limit queries. Update Codex CLI. \(detail)"
        case .codexRequestTimedOut(let method):
            "The read-only \(method) request timed out. The app will retry according to its backoff policy."
        case .codexAppServerUnavailable(let detail): detail
        }
    }

    private static func localizedDetail(_ detail: String) -> String {
        let exact: [String: String] = [
            "Command output is not a JSON object": "指令輸出不是 JSON 物件",
            "The CLI reported is_error for /usage": "CLI 對 /usage 回報 is_error",
            "The CLI did not report subtype=success for /usage": "CLI 未對 /usage 回報 subtype=success",
            "Missing result text": "缺少 result 文字",
            "Codex rate-limit response is not a JSON object": "Codex rate-limit 回應不是 JSON 物件",
            "Missing standard codex rateLimits": "缺少一般 codex rateLimits",
            "Standard codex rateLimits has no decodable primary or secondary window": "一般 codex rateLimits 缺少可解析的 primary／secondary",
            "Codex usedPercent must be an integer from 0 through 100": "Codex usedPercent 必須是 0 到 100 的整數",
            "Codex windowDurationMins must be an integer or null": "Codex windowDurationMins 必須是整數或 null",
            "Codex resetsAt must be an integer or null": "Codex resetsAt 必須是整數或 null",
            "Codex App Server sent more than 4 MB without a newline": "Codex App Server 傳來超過 4 MB 且未換行的資料",
            "Data is from the previous app session": "資料為上次執行時取得",
            "Codex CLI path changed; waiting to reconnect": "Codex CLI 路徑已變更，等待重新連線",
            "Codex App Server was stopped by the app": "Codex App Server 已由 App 停止",
            "Codex CLI path changed": "Codex CLI 路徑已變更",
            "Codex App Server is not running": "Codex App Server 尚未執行",
        ]
        if let translated = exact[detail] { return translated }

        let replacements: [(String, String)] = [
            ("Missing the \"", "找不到「"),
            ("Missing reset time in \"", "缺少重置時間：「"),
            ("Found ", "找到 "),
            ("Unreadable \"", "無法解析「"),
            ("Unreadable percentage in \"", "無法讀取百分比：「"),
            ("Percentage ", "百分比 "),
            ("Unreadable reset time in \"", "無法讀取重置時間：「"),
            ("Could not run ", "無法執行 "),
            ("Could not start ", "無法啟動 "),
            ("Failed to write to Codex App Server: ", "寫入 Codex App Server 失敗："),
            ("App Server error ", "App Server 錯誤 "),
            ("Codex App Server stopped unexpectedly (exit ", "Codex App Server 意外停止（exit "),
        ]
        for (english, chinese) in replacements where detail.hasPrefix(english) {
            var translated = chinese + detail.dropFirst(english.count)
            if translated.hasSuffix(")") { translated.removeLast(); translated.append("）") }
            if translated.hasSuffix("\" line") {
                translated.removeLast(6)
                translated.append("」這一行")
            } else if translated.hasSuffix("\"") {
                // Closes the quote the prefix replacement opened. Without this the
                // Chinese message ends on a stray ASCII quote.
                translated.removeLast()
                translated.append("」")
            }
            return translated
        }
        return detail
    }
}
