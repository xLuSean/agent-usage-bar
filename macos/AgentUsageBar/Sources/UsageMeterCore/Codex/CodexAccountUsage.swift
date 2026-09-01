import Foundation

/// Account-level token totals reported by Codex `account/usage/read`.
///
/// These buckets are provider history embedded in the latest snapshot. Agent Usage Bar
/// does not derive them from local tasks and does not accumulate its own sample history.
public struct CodexAccountUsage: Sendable, Hashable, Codable {
    public struct DailyBucket: Sendable, Hashable, Codable, Identifiable {
        /// A validated Gregorian date in the provider's `yyyy-MM-dd` wire format.
        public let startDate: String
        public let tokens: Int

        public var id: String { startDate }

        public init(startDate: String, tokens: Int) {
            self.startDate = startDate
            self.tokens = tokens
        }
    }

    public let lifetimeTokens: Int?
    public let peakDailyTokens: Int?
    public let dailyUsageBuckets: [DailyBucket]
    /// When this account-usage response was accepted. Optional so snapshots written by
    /// the first token-history build remain decodable after the two schedules split.
    public let fetchedAt: Date?

    public init(
        lifetimeTokens: Int?,
        peakDailyTokens: Int?,
        dailyUsageBuckets: [DailyBucket],
        fetchedAt: Date? = nil
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.dailyUsageBuckets = dailyUsageBuckets
        self.fetchedAt = fetchedAt
    }

    public var updatedThrough: String? {
        dailyUsageBuckets.last?.startDate
    }

    /// Returns the newest bounded slice without changing the provider response held by
    /// the snapshot. Display preferences use this instead of pruning persisted data.
    public func mostRecentDailyBuckets(limit: Int) -> [DailyBucket] {
        guard limit > 0 else { return [] }
        return Array(dailyUsageBuckets.suffix(limit))
    }

    /// Daily bucket labels do not carry a timezone. For the user-facing "Today" row,
    /// compare them with the calendar day on this Mac rather than assuming that a
    /// missing bucket means zero usage.
    public func tokens(on date: Date, timeZone: TimeZone = .current) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        let dayLabel = String(format: "%04d-%02d-%02d", year, month, day)
        return dailyUsageBuckets.first(where: { $0.startDate == dayLabel })?.tokens
    }

    /// Persisted snapshots are untrusted input on relaunch. The live decoder applies the
    /// same checks before construction; this closes the equivalent disk boundary.
    public var isValid: Bool {
        guard lifetimeTokens.map({ $0 >= 0 }) ?? true,
              peakDailyTokens.map({ $0 >= 0 }) ?? true,
              dailyUsageBuckets.count <= CodexAccountUsageDecoder.maximumDailyBuckets else {
            return false
        }

        var previousDate: String?
        for bucket in dailyUsageBuckets {
            guard bucket.tokens >= 0,
                  CodexAccountUsageDecoder.isCanonicalDate(bucket.startDate),
                  previousDate.map({ $0 < bucket.startDate }) ?? true else {
                return false
            }
            previousDate = bucket.startDate
        }
        return true
    }
}

/// Strictly normalizes the documented account usage response. Unknown fields, including
/// `threadUsage`, are ignored and raw provider JSON is never retained.
public enum CodexAccountUsageDecoder {
    static let maximumDailyBuckets = 400

    public static func decode(
        _ data: Data,
        fetchedAt: Date = Date()
    ) throws -> CodexAccountUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.schemaChanged("Codex account usage response is not a JSON object")
        }
        guard root.keys.contains("summary") || root.keys.contains("dailyUsageBuckets") else {
            throw UsageError.schemaChanged("Codex account usage response has no documented usage fields")
        }

        let summary: [String: Any]?
        switch root["summary"] {
        case nil, is NSNull:
            summary = nil
        case let value as [String: Any]:
            summary = value
        default:
            throw UsageError.schemaChanged("Codex account usage summary must be an object or null")
        }

        let lifetimeTokens = try optionalNonnegativeInteger(summary?["lifetimeTokens"], key: "lifetimeTokens")
        let peakDailyTokens = try optionalNonnegativeInteger(summary?["peakDailyTokens"], key: "peakDailyTokens")
        let buckets = try decodeBuckets(root["dailyUsageBuckets"])

        return CodexAccountUsage(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakDailyTokens,
            dailyUsageBuckets: buckets,
            fetchedAt: fetchedAt
        )
    }

    private static func decodeBuckets(_ value: Any?) throws -> [CodexAccountUsage.DailyBucket] {
        guard let value, !(value is NSNull) else { return [] }
        guard let rawBuckets = value as? [[String: Any]] else {
            throw UsageError.schemaChanged("Codex dailyUsageBuckets must be an array or null")
        }
        guard rawBuckets.count <= maximumDailyBuckets else {
            throw UsageError.schemaChanged("Codex dailyUsageBuckets exceeds the supported size")
        }

        var buckets: [CodexAccountUsage.DailyBucket] = []
        var seenDates = Set<String>()
        for raw in rawBuckets {
            guard let startDate = raw["startDate"] as? String,
                  isCanonicalDate(startDate) else {
                throw UsageError.schemaChanged("Codex daily usage startDate must use yyyy-MM-dd")
            }
            guard seenDates.insert(startDate).inserted else {
                throw UsageError.schemaChanged("Codex daily usage contains duplicate dates")
            }
            let tokens = try requiredNonnegativeInteger(raw["tokens"], key: "daily tokens")
            buckets.append(.init(startDate: startDate, tokens: tokens))
        }
        return buckets.sorted { $0.startDate < $1.startDate }
    }

    private static func optionalNonnegativeInteger(_ value: Any?, key: String) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        return try requiredNonnegativeInteger(value, key: key)
    }

    private static func requiredNonnegativeInteger(_ value: Any?, key: String) throws -> Int {
        guard let integer = CodexJSONNumber.exactInteger(value), integer >= 0 else {
            throw UsageError.schemaChanged("Codex \(key) must be a nonnegative integer")
        }
        return integer
    }

    static func isCanonicalDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9_999).contains(year) else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }
}
