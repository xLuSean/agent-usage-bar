import Foundation

/// Reads the rows of `usage_report.rate_limits.limits`.
///
/// # Two kinds of row, two levels of strictness
///
/// The gauge and the stored reading are built on exactly two meters: the session
/// window and the all-models weekly window. Those rows are read strictly. A figure out
/// of range, a missing reset where one is required, or two rows claiming the same meter
/// fails the whole reading, for the same reason the prose decoder fails closed.
///
/// Every other row is a meter the server chose to add: a per-model weekly limit today,
/// whatever comes next tomorrow. Those are shown when they can be read and left out
/// when they cannot. A row this build cannot interpret must not be able to take the two
/// required figures down with it, and leaving a row out never puts a wrong number on
/// screen.
///
/// # What is deliberately not read
///
/// The colour hint each row carries is ignored: gauge colour comes from the percentage
/// alone, on one scale shared with Codex (UI spec §3.1). The report's usage-credits
/// block is ignored as well. This app shows quota windows, not billing.
enum ClaudeUsageReportDecoder {

    /// More rows than any real account has, and few enough to bound the panel and the
    /// stored reading if the list ever arrives malformed.
    static let maximumAdditionalRows = 16

    /// - Returns: the session window, the all-models weekly window, then every other
    ///   readable row in the server's order; or `nil` when either required meter is
    ///   absent from the rows.
    static func windows(from rows: [Any], now: Date) throws -> [UsageWindow]? {
        let objects = rows.compactMap { $0 as? [String: Any] }

        // Both are decoded before either is required, so a malformed weekly row is
        // reported as malformed rather than hidden behind a missing session row.
        let session = try required(.session, group: .session, in: objects)
        let weekly = try required(.weeklyAll, group: .weekly, in: objects)
        guard let session, let weekly else { return nil }

        let additional = objects.compactMap { additionalWindow($0, now: now) }
        // Identity is kind plus label, and both the panel and the remembered
        // collapsed rows are keyed by it. Two rows with one identity cannot both be
        // shown, and choosing between them would be a guess.
        let occurrences = Dictionary(grouping: additional, by: \.id).mapValues(\.count)
        let distinct = additional.filter { occurrences[$0.id] == 1 }

        return [session, weekly] + distinct.prefix(maximumAdditionalRows)
    }

    // MARK: - The two required meters

    private static func required(
        _ kind: UsageWindow.Kind,
        group: UsageWindow.Group,
        in rows: [[String: Any]]
    ) throws -> UsageWindow? {
        // A constant of this build, never provider text, so it is safe in an error.
        let label = kind.rawValue
        let matches = rows.filter { $0["kind"] as? String == label }

        guard let row = matches.first else { return nil }
        guard matches.count == 1 else {
            throw UsageError.schemaChanged("Found \(matches.count) \"\(label)\" usage rows")
        }
        guard let used = percent(row["percent"]) else {
            throw UsageError.schemaChanged("Unreadable percentage in the \"\(label)\" usage row")
        }

        let resetsAt: Date?
        switch resetTime(row["resets_at"]) {
        case .time(let date):
            resetsAt = date
        case .unreadable:
            throw UsageError.schemaChanged("Unreadable reset time in the \"\(label)\" usage row")
        case .absent:
            // The same rule the prose decoder applies, and the one `UsageSnapshotStore`
            // enforces again before saving. The weekly window is always running, so it
            // always has a reset. The session window is anchored to first use, so it
            // has none between one ending and the next starting — but only then, and
            // then it reads zero. A nonzero figure with no reset is incomplete data,
            // not permission to skip the staleness guard.
            guard kind == .session, used.usedPercent == 0 else {
                throw UsageError.schemaChanged("Missing reset time in the \"\(label)\" usage row")
            }
            resetsAt = nil
        }

        return UsageWindow(
            kind: kind,
            group: group,
            used: used,
            resetsAt: resetsAt,
            isActive: flag(row["is_active"])
        )
    }

    // MARK: - Every other row

    private static func additionalWindow(_ row: [String: Any], now: Date) -> UsageWindow? {
        guard let rawKind = row["kind"] as? String,
              rawKind != UsageWindow.Kind.session.rawValue,
              rawKind != UsageWindow.Kind.weeklyAll.rawValue,
              // An unfamiliar kind is displayed under its own name, so it has to be
              // something safe to display and to store.
              ProviderMetadataText.isSafeIdentifier(rawKind),
              let rawGroup = row["group"] as? String,
              ProviderMetadataText.isSafeIdentifier(rawGroup),
              let used = percent(row["percent"]) else { return nil }

        let resetsAt: Date?
        switch resetTime(row["resets_at"]) {
        case .time(let date): resetsAt = date
        case .absent: resetsAt = nil
        case .unreadable: return nil
        }
        // A row whose window has already ended describes nothing current.
        if let resetsAt, resetsAt.addingTimeInterval(ClaudeUsageTextDecoder.resetGrace) < now {
            return nil
        }

        return UsageWindow(
            kind: UsageWindow.Kind(rawValue: rawKind),
            group: UsageWindow.Group(rawValue: rawGroup),
            used: used,
            resetsAt: resetsAt,
            isActive: flag(row["is_active"]),
            modelDisplayName: scopeLabel(row["scope"])
        )
    }

    /// What a scoped row applies to: a model, or failing that a surface. This is
    /// provider text, so it passes the same bound as every other label before it can
    /// reach the panel or the stored reading.
    private static func scopeLabel(_ value: Any?) -> String? {
        guard let scope = value as? [String: Any] else { return nil }
        for key in ["model", "surface"] {
            let name = (scope[key] as? [String: Any])?["display_name"] as? String
            if let label = ProviderMetadataText.normalizedDisplay(name) { return label }
        }
        return nil
    }

    // MARK: - Fields

    /// Documented as 0–100. A value outside that range means this is not a percentage,
    /// so it is unreadable rather than clamped: clamping would turn a misread into a
    /// confident 100%.
    private static func percent(_ value: Any?) -> UsedPercent? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, (0...100).contains(raw) else { return nil }
        return UsedPercent(hundredScale: raw)
    }

    /// Absent on reports from before the field was guaranteed, which is not the same as
    /// the server saying a row is binding. Only an actual `true` counts.
    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, isBoolean(number) else { return false }
        return number.boolValue
    }

    /// JSON `true` arrives as an `NSNumber` that reads as `1.0`. Without this check a
    /// boolean in a numeric field would decode as one percent.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private enum ResetTime {
        case absent
        case unreadable
        case time(Date)
    }

    private static func resetTime(_ value: Any?) -> ResetTime {
        guard let value, !(value is NSNull) else { return .absent }
        guard let text = value as? String, let date = TimeFormatting.parseISO8601(text) else {
            return .unreadable
        }
        return .time(date)
    }
}
