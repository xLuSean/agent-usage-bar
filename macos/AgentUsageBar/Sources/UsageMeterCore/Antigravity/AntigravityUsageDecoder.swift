import Foundation

/// Decodes the JSON output of `agy -p /usage --output-format json`.
///
/// Strictly fail-closed on the envelope and on every quota bucket:
/// - Rejects non-SUCCESS status or nonzero `num_turns` (never accepts a model turn).
/// - Requires `command.name == "usage"` and a valid `command.data.groups` array.
/// - Converts `remaining_fraction` (`0...1`) to `UsedPercent` without letting a tiny
///   positive remainder round into a false 100% exhausted state.
/// - Enforces the shared 60-second reset grace so stale windows are never presented as
///   current readings.
public enum AntigravityUsageDecoder {

    /// Bounds the number of model groups and total buckets accepted from one response.
    public static let maximumGroups = 16
    public static let maximumBuckets = 32

    /// Matches Claude's and `UsageSnapshotStore`'s reset boundary grace.
    static let resetGrace: TimeInterval = 60

    public static func decode(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.schemaChanged("Command output is not a JSON object")
        }
        guard let envelope = jsonObject as? [String: Any] else {
            throw UsageError.schemaChanged("Command output is not a JSON object")
        }

        guard let status = envelope["status"] as? String else {
            throw UsageError.antigravityCommandFailed("Antigravity CLI did not report status=SUCCESS")
        }
        guard status.uppercased() == "SUCCESS" else {
            throw UsageError.antigravityCommandFailed("Antigravity CLI did not report status=SUCCESS")
        }

        if let turns = strictInt(envelope["num_turns"]), turns != 0 {
            throw UsageError.schemaChanged("Antigravity /usage response executed a model turn")
        } else if envelope["num_turns"] != nil && !(envelope["num_turns"] is NSNull) && strictInt(envelope["num_turns"]) == nil {
            throw UsageError.schemaChanged("Antigravity /usage response executed a model turn")
        }

        guard let command = envelope["command"] as? [String: Any],
              command["name"] as? String == "usage",
              let commandData = command["data"] as? [String: Any] else {
            throw UsageError.schemaChanged("Antigravity /usage command payload is missing")
        }

        guard let rawGroups = commandData["groups"] else {
            throw UsageError.antigravityUsageUnavailable
        }
        if rawGroups is NSNull {
            throw UsageError.antigravityUsageUnavailable
        }
        guard let groupArray = rawGroups as? [Any] else {
            throw UsageError.schemaChanged("Antigravity /usage groups array is unreadable")
        }

        var windows: [UsageWindow] = []
        var seenIDs = Set<String>()

        for rawGroup in groupArray.prefix(maximumGroups) {
            guard let groupObject = rawGroup as? [String: Any],
                  let rawGroupName = groupObject["name"] as? String,
                  let groupName = ProviderMetadataText.normalizedDisplay(rawGroupName) else {
                throw UsageError.schemaChanged("Antigravity /usage groups array is unreadable")
            }

            guard let rawBuckets = groupObject["buckets"] else { continue }
            if rawBuckets is NSNull { continue }
            guard let bucketArray = rawBuckets as? [Any] else {
                throw UsageError.schemaChanged("Antigravity /usage groups array is unreadable")
            }

            for rawBucket in bucketArray {
                guard windows.count < maximumBuckets else { break }
                guard let bucketObject = rawBucket as? [String: Any] else {
                    throw UsageError.schemaChanged("Antigravity /usage groups array is unreadable")
                }

                guard let rawWindow = bucketObject["window"] as? String,
                      ProviderMetadataText.isSafeIdentifier(rawWindow) else {
                    throw UsageError.schemaChanged("Antigravity /usage groups array is unreadable")
                }

                guard let remaining = strictUnitFraction(bucketObject["remaining_fraction"]) else {
                    throw UsageError.schemaChanged("Antigravity /usage bucket remaining_fraction is invalid")
                }

                let resetsAt: Date?
                switch parseResetTime(bucketObject["reset_time"]) {
                case .time(let date):
                    if date.addingTimeInterval(resetGrace) < now {
                        throw UsageError.antigravityUsageOutdated(resetsAt: date)
                    }
                    resetsAt = date
                case .absent:
                    resetsAt = nil
                case .unreadable:
                    throw UsageError.schemaChanged("Antigravity /usage bucket reset_time is invalid")
                }

                let (kind, group, durationMinutes) = Self.classifyWindow(rawWindow)
                let window = UsageWindow(
                    kind: kind,
                    group: group,
                    used: Self.usedPercent(fromRemainingFraction: remaining),
                    resetsAt: resetsAt,
                    isActive: false,
                    modelDisplayName: groupName,
                    durationMinutes: durationMinutes
                )
                guard seenIDs.insert(window.id).inserted else {
                    throw UsageError.schemaChanged("Antigravity /usage contains duplicate quota buckets")
                }
                windows.append(window)
            }
        }

        guard !windows.isEmpty else {
            throw UsageError.antigravityUsageUnavailable
        }

        return UsageSnapshot(
            provider: .antigravity,
            sourcePath: .antigravityCLI,
            windows: windows,
            fetchedAt: now
        )
    }

    private static func classifyWindow(_ rawWindow: String) -> (UsageWindow.Kind, UsageWindow.Group, Int?) {
        switch rawWindow.lowercased() {
        case "5h":
            return (.sessionScoped, .session, 300)
        case "weekly", "7d":
            return (.weeklyScoped, .weekly, 10_080)
        default:
            return (.unrecognized(rawWindow), .unrecognized(rawWindow), nil)
        }
    }

    /// Converts a remaining fraction (`0...1`) into a `UsedPercent`.
    ///
    /// A tiny positive remainder (for example, `0.002`) would otherwise round to `100%`
    /// used and render as exhausted even though quota still remains. Only an exact `0`
    /// remaining fraction maps to `100%` used.
    static func usedPercent(fromRemainingFraction remaining: Double) -> UsedPercent {
        if remaining == 0 {
            return UsedPercent(normalized: 100, originalScale: .unit)
        }
        let rawUsedPercent = (1.0 - remaining) * 100.0
        if rawUsedPercent.rounded() >= 100 {
            return UsedPercent(normalized: 99, originalScale: .unit)
        }
        return UsedPercent(unitScale: 1.0 - remaining)
    }

    private static func strictUnitFraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, (0.0...1.0).contains(doubleValue) else {
            return nil
        }
        return doubleValue
    }

    private static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue.rounded(.towardZero) == doubleValue else {
            return nil
        }
        return Int(exactly: doubleValue)
    }

    private enum ResetTimeParseResult {
        case time(Date)
        case absent
        case unreadable
    }

    private static func parseResetTime(_ value: Any?) -> ResetTimeParseResult {
        guard let value, !(value is NSNull) else { return .absent }
        guard let raw = value as? String else { return .unreadable }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .absent }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return .time(date)
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        if let date = wholeSeconds.date(from: trimmed) {
            return .time(date)
        }
        return .unreadable
    }
}
