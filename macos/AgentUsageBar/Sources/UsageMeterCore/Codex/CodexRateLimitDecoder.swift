import Foundation

/// Decodes only the documented, read-only rate-limit response. Unknown fields are
/// ignored and recorded by name; no raw upstream payload is retained.
public enum CodexRateLimitDecoder {
    public static func decode(
        _ data: Data,
        fetchedAt: Date,
        serverUserAgent: String? = nil,
        accountUsage: CodexAccountUsage? = nil
    ) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.schemaChanged("Codex rate-limit response is not a JSON object")
        }

        let bucket = preferredBucket(in: root)
        guard let bucket else {
            throw UsageError.schemaChanged("Missing standard codex rateLimits")
        }

        let limitID = try ProviderMetadataText.identifier(bucket["limitId"], default: "codex")
        let limitName = ProviderMetadataText.normalizedDisplay(bucket["limitName"] as? String)
        let reachedType = ProviderMetadataText.normalizedDisplay(bucket["rateLimitReachedType"] as? String)

        var windows: [UsageWindow] = []
        if let primary = bucket["primary"] as? [String: Any] {
            windows.append(try makeWindow(
                primary,
                position: .primary,
                limitID: limitID,
                limitName: limitName
            ))
        }
        if let secondary = bucket["secondary"] as? [String: Any] {
            windows.append(try makeWindow(
                secondary,
                position: .secondary,
                limitID: limitID,
                limitName: limitName
            ))
        }

        guard !windows.isEmpty else {
            throw UsageError.schemaChanged("Standard codex rateLimits has no decodable primary or secondary window")
        }

        return UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: windows,
            fetchedAt: fetchedAt,
            credits: credits(from: bucket["credits"]),
            planType: ProviderMetadataText.normalizedDisplay(bucket["planType"] as? String),
            rateLimitReachedType: reachedType,
            spendControlReached: bucket["spendControlReached"] as? Bool,
            meteredLimitID: limitID,
            sourceVersion: ProviderMetadataText.normalizedDisplay(serverUserAgent),
            codexAccountUsage: accountUsage
        )
    }

    private enum Position { case primary, secondary }

    /// Prefer the multi-bucket entry named `codex`, then fall back to the documented
    /// backward-compatible single-bucket view. Extra limit IDs are intentionally not
    /// surfaced in MVP, but their presence never makes the general bucket fail.
    private static func preferredBucket(in root: [String: Any]) -> [String: Any]? {
        if let buckets = root["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return root["rateLimits"] as? [String: Any]
    }

    private static func makeWindow(
        _ raw: [String: Any],
        position: Position,
        limitID: String,
        limitName: String?
    ) throws -> UsageWindow {
        guard let used = CodexJSONNumber.exactInteger(raw["usedPercent"]),
              (0...100).contains(used) else {
            throw UsageError.schemaChanged("Codex usedPercent must be an integer from 0 through 100")
        }
        let duration = try optionalInteger(raw, key: "windowDurationMins")
        let reset = try optionalInteger(raw, key: "resetsAt")
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let kind: UsageWindow.Kind
        let group: UsageWindow.Group
        switch position {
        case .primary:
            kind = .session
            group = .session
        case .secondary:
            kind = limitID == "codex" ? .weeklyAll : .weeklyScoped
            group = .weekly
        }

        return UsageWindow(
            kind: kind,
            group: group,
            used: UsedPercent(hundredScale: Double(used)),
            resetsAt: reset,
            // The product's gauge represents the documented general primary bucket.
            isActive: limitID == "codex" && position == .primary,
            modelDisplayName: limitID == "codex" ? nil : (limitName ?? limitID),
            durationMinutes: duration
        )
    }

    private static func credits(from value: Any?) -> UsageCredits? {
        guard let raw = value as? [String: Any],
              let hasCredits = raw["hasCredits"] as? Bool,
              let unlimited = raw["unlimited"] as? Bool else { return nil }
        return UsageCredits(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: ProviderMetadataText.normalizedDisplay(raw["balance"] as? String)
        )
    }

    private static func optionalInteger(_ raw: [String: Any], key: String) throws -> Int? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let integer = CodexJSONNumber.exactInteger(value) else {
            throw UsageError.schemaChanged("Codex \(key) must be an integer or null")
        }
        return integer
    }
}
