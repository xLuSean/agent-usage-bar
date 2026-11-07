import Foundation

/// Only facts attributable to this read are allowed into diagnostic history.
public struct CodexQueryDiagnostic: Codable, Sendable, Hashable {
    struct BackgroundProcess: Codable, Sendable, Hashable {
        let id: UUID
        let startedAt: Date
        var reused: Bool

        init(startedAt: Date = Date(), reused: Bool = false) {
            id = UUID()
            self.startedAt = startedAt
            self.reused = reused
        }
    }

    let method: CodexJSONRPCMethod
    var process: BackgroundProcess?
    var failedDuringInitialization: Bool?
    var rpc: CodexRPCRejection?
    var processExit: CodexProcessExit?

    func failure(_ error: any Error) -> CodexQueryFailure {
        var query = self
        if let startup = error as? CodexQueryFailure {
            guard startup.diagnostic.method == .initialize else { return startup }
            query.process = startup.diagnostic.process
            query.rpc = startup.diagnostic.rpc
            query.processExit = startup.diagnostic.processExit
            if query.process != nil { query.failedDuringInitialization = true }
            return CodexQueryFailure(error: startup.error, diagnostic: query)
        }
        if let rejection = error as? CodexRPCRejection {
            query.rpc = rejection
            return CodexQueryFailure(error: rejection.usageError(for: method), diagnostic: query)
        }
        if let exit = error as? CodexProcessExit {
            query.processExit = exit
            return CodexQueryFailure(error: exit.usageError, diagnostic: query)
        }
        return CodexQueryFailure(
            error: (error as? UsageError) ?? .transport(error.localizedDescription),
            diagnostic: query
        )
    }

    func message(fallback: String, locale: Locale) -> String {
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        let operation = switch method {
        case .initialize: chinese ? "建立 Codex 連線" : "Initialize Codex connection"
        case .rateLimitsRead: chinese ? "查詢 Codex 額度" : "Read Codex quota"
        case .accountUsageRead: chinese ? "查詢 Codex Token 用量" : "Read Codex token usage"
        }
        var lines = [chinese ? "\(operation)（\(method.rawValue)）" : "\(operation) (\(method.rawValue))"]
        if failedDuringInitialization == true {
            lines.append(chinese ? "建立連線時失敗（initialize）。" : "Connection initialization failed (initialize).")
        }
        if let rpc {
            lines.append(rpc.message(locale: locale))
        } else if let processExit {
            lines.append(processExit.message(locale: locale))
        } else {
            lines.append(fallback)
        }
        if let process {
            let time = process.startedAt.formatted(Date.FormatStyle(date: .numeric, time: .standard, locale: locale))
            if chinese {
                lines.append(process.reused ? "沿用 \(time) 啟動的背景程序。" : "使用本次新啟動的背景程序（\(time)）。")
            } else {
                lines.append(process.reused ? "Reused the background process started at \(time)." :
                    "Used a new background process started at \(time).")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Captured from an owned Foundation Process after it exits, independently of RPC text.
struct CodexProcessExit: Error, Codable, Sendable, Hashable {
    let status: Int32
    let signalled: Bool

    init(_ process: Process) {
        status = process.terminationStatus
        signalled = process.terminationReason == .uncaughtSignal
    }

    var usageError: UsageError {
        let reason = signalled ? "signal" : "exit"
        return .codexAppServerUnavailable("Codex App Server stopped unexpectedly (\(reason) \(status))")
    }

    func message(locale: Locale) -> String {
        if TimeFormatting.usesTraditionalChinese(locale) {
            return signalled ? "Codex 背景程序被訊號 \(status) 終止。" : "Codex 背景程序意外結束（退出碼 \(status)）。"
        }
        return signalled ? "The Codex background process was terminated by signal \(status)." :
            "The Codex background process stopped unexpectedly (exit code \(status))."
    }
}

/// The presenter uses the original category for the gauge and the safe facts for its log.
public struct CodexQueryFailure: Error, Sendable {
    public let error: UsageError
    public let diagnostic: CodexQueryDiagnostic

    static func withOriginalError<T: Sendable>(_ read: @Sendable () async throws -> T) async throws -> T {
        do { return try await read() }
        catch let failure as CodexQueryFailure { throw failure.error }
    }
}

/// Some CLI versions embed the HTTP status and a JSON service error in error.message.
/// Reduce them at the protocol boundary. Neither the message nor its body leaves here.
struct CodexRPCRejection: Error, Codable, Sendable, Hashable {
    enum Reason: String, Codable, Sendable {
        case tokenExpired, notLoggedIn, unsupported, unspecified
    }

    enum ServiceCode: String, Codable, Sendable {
        case tokenExpired = "token_expired"
    }

    let code: Int
    let httpStatus: Int?
    let reason: Reason
    let reportedServiceCode: ServiceCode?

    init(code: Int, message: String, data: [String: Any]? = nil) {
        self.code = code
        let bodySeparator = message.range(of: "; body=")
        let header = message[..<(bodySeparator?.lowerBound ?? message.endIndex)]
        let body = bodySeparator.flatMap {
            (try? JSONSerialization.jsonObject(with: Data(message[$0.upperBound...].utf8))) as? [String: Any]
        }
        let statuses = [
            Self.statusInHeader(header),
            CodexJSONNumber.exactInteger(data?["status"]),
            CodexJSONNumber.exactInteger(body?["status"]),
        ]
        httpStatus = statuses.compactMap { $0 }.first { (400...599).contains($0) }

        let serviceError = (body?["error"] as? [String: Any]) ?? (data?["error"] as? [String: Any])
        let codeSources = [serviceError?["code"] as? String, data?["code"] as? String, message]
        reportedServiceCode = codeSources.compactMap { $0.flatMap(ServiceCode.init(rawValue:)) }.first
        let lower = message.lowercased()
        let expiredMessage = "your authentication token has expired. please try refreshing it."
        if code == -32601 {
            reason = .unsupported
        } else if reportedServiceCode == .tokenExpired || lower == ServiceCode.tokenExpired.rawValue
                    || lower == expiredMessage || (serviceError?["message"] as? String)?.lowercased() == expiredMessage {
            reason = .tokenExpired
        } else if httpStatus == nil, bodySeparator == nil, Self.reportsUnsupportedMethod(lower) {
            reason = .unsupported
        } else if lower.contains("not logged in") || lower.contains("not authenticated")
                    || lower.contains("authentication required") || lower.contains("login required") {
            reason = .notLoggedIn
        } else {
            reason = .unspecified
        }
    }

    private static func reportsUnsupportedMethod(_ message: String) -> Bool {
        let label = message.prefix { $0 != ":" }.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["method not found", "unknown method", "unsupported method", "method not supported"].contains(label) {
            return true
        }
        return CodexJSONRPCMethod.allCases.contains { method in
            let name = method.rawValue.lowercased()
            return label == "\(name) is not supported" || label == "method \(name) is not supported"
        }
    }

    private static func statusInHeader(_ header: Substring) -> Int? {
        let start = header.range(of: " failed: ", options: .backwards)?.upperBound ?? header.startIndex
        let status = header[start...].trimmingPrefix("HTTP ").prefix { !$0.isWhitespace && $0 != ";" }
        return status.count == 3 ? Int(status) : nil
    }

    func usageError(for method: CodexJSONRPCMethod) -> UsageError {
        switch reason {
        case .unsupported:
            .codexVersionIncompatible("The selected Codex App Server does not support \(method.rawValue).")
        case .notLoggedIn:
            .codexNotLoggedIn
        case .tokenExpired, .unspecified:
            .codexAppServerUnavailable("Codex App Server returned error code \(code).")
        }
    }

    func message(locale: Locale) -> String {
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        let explanation = switch reason {
        case .tokenExpired: chinese ? "登入憑證已過期" : "The sign-in token expired"
        case .notLoggedIn: chinese ? "Codex 要求登入" : "Codex requires sign-in"
        case .unsupported: chinese ? "Codex 不支援這個方法" : "Codex does not support this method"
        case .unspecified: chinese ? "Codex 未提供可辨識的詳細原因" : "Codex supplied no recognized cause"
        }
        var codes = ["RPC \(code)"]
        if let httpStatus { codes.append("HTTP \(httpStatus)") }
        if let reportedServiceCode { codes.append(reportedServiceCode.rawValue) }
        return chinese ? "\(explanation)（\(codes.joined(separator: "、"))）。" :
            "\(explanation) (\(codes.joined(separator: ", ")))."
    }
}
