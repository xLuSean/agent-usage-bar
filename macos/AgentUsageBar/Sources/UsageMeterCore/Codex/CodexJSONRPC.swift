import Foundation

/// JSON Schema's `integer` accepts whole numeric values, but never silently truncates
/// a fractional number. Keep the check shared by envelopes and provider payloads so a
/// malformed value cannot mean two different things on the same connection.
enum CodexJSONNumber {
    static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c" else { return nil }

        if type == "f" || type == "d" {
            return Int(exactly: number.doubleValue)
        }
        return Int(number.stringValue)
    }
}

enum CodexJSONRPCMethod: String, Sendable {
    case initialize
    case rateLimitsRead = "account/rateLimits/read"
    case accountUsageRead = "account/usage/read"
}

enum CodexJSONRPCNotificationMethod: String, Sendable {
    case initialized
}

/// The only outbound messages this provider can construct. Keeping methods in closed
/// enums is the allow-list; there is no arbitrary-method entry point.
enum CodexJSONRPC {
    static func request(
        _ method: CodexJSONRPCMethod,
        id: Int,
        params: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = ["method": method.rawValue, "id": id]
        if let params { object["params"] = params }
        return try lineData(object)
    }

    static func notification(
        _ method: CodexJSONRPCNotificationMethod,
        params: [String: Any] = [:]
    ) throws -> Data {
        try lineData(["method": method.rawValue, "params": params])
    }

    private static func lineData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

enum CodexJSONRPCInbound: Sendable, Hashable {
    case result(id: Int, payload: Data)
    case failure(id: Int, code: Int, message: String)
    case notification(method: String, payload: Data)
    case ignored
}

enum CodexJSONRPCParser {
    static func parse(_ line: Data) -> CodexJSONRPCInbound {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .ignored
        }

        if let id = CodexJSONNumber.exactInteger(object["id"]) {
            if let result = object["result"], JSONSerialization.isValidJSONObject(result),
               let payload = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                return .result(id: id, payload: payload)
            }
            if let error = object["error"] as? [String: Any],
               let code = CodexJSONNumber.exactInteger(error["code"]),
               let message = error["message"] as? String {
                return .failure(id: id, code: code, message: message)
            }
            return .ignored
        }

        if let method = object["method"] as? String {
            let params = object["params"] ?? [:]
            guard JSONSerialization.isValidJSONObject(params),
                  let payload = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]) else {
                return .ignored
            }
            return .notification(method: method, payload: payload)
        }
        return .ignored
    }
}

/// Incremental JSONL framing. Lines may arrive split across reads or several at once.
struct CodexJSONLBuffer: Sendable {
    private var buffer = Data()
    private let maximumBufferedBytes = 4 * 1024 * 1024

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)

        var lines: [Data] = []
        var lineStart = buffer.startIndex
        for newline in buffer.indices where buffer[newline] == 0x0A {
            let lineLength = buffer.distance(from: lineStart, to: newline)
            guard lineLength <= maximumBufferedBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw UsageError.schemaChanged("Codex App Server sent more than 4 MB without a newline")
            }

            var line = Data(buffer[lineStart..<newline])
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
            lineStart = buffer.index(after: newline)
        }

        let trailingBytes = buffer.distance(from: lineStart, to: buffer.endIndex)
        guard trailingBytes <= maximumBufferedBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw UsageError.schemaChanged("Codex App Server sent more than 4 MB without a newline")
        }
        if lineStart != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        return lines
    }
}
