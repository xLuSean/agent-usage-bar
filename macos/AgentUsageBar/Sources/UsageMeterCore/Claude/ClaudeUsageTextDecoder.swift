import Foundation

/// Decodes `claude -p "/usage" --output-format json`.
///
/// # Two layers, and only one of them is a contract
///
/// The outer envelope is real JSON with stable keys (`is_error`, `subtype`, `result`).
/// The figures this app needs are *inside* `result`, as English prose written for a
/// person to read. There is no field schema for them.
///
/// So everything here fails closed. A line that does not match exactly is a schema
/// change, not an invitation to guess: no `0%`, no partial reading, no reuse of a
/// previous value. Showing "unknown" costs the user one glance; showing a wrong number
/// costs them the decision they made because of it.
///
/// # What is deliberately thrown away
///
/// `result` also carries a local-activity breakdown — request counts, session counts,
/// which skills and MCP servers were used, and what share each accounted for. None of
/// it is needed here and all of it is the user's private working history. It is never
/// parsed, never stored, never shown, and never quoted in an error. The same goes for
/// the envelope's one-shot `session_id`.
public enum ClaudeUsageTextDecoder {

    /// Absorbs clock skew and the one-second gap between the endpoint's real boundary
    /// (`00:59:59`) and how the text renders it (`1am`). Small enough that a genuinely
    /// rolled-over window is still caught within a minute.
    static let resetGrace: TimeInterval = 60

    public static func decode(
        _ data: Data,
        now: Date,
        sourceVersion: String? = nil,
        timeZone: TimeZone = .current
    ) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.schemaChanged("Command output is not a JSON object")
        }

        // `is_error` absent is treated as an error rather than as success: a missing
        // success signal is not the same thing as a success signal.
        guard root["is_error"] as? Bool == false else {
            throw UsageError.claudeCommandFailed("The CLI reported is_error for /usage")
        }
        guard let subtype = root["subtype"] as? String, subtype == "success" else {
            throw UsageError.claudeCommandFailed("The CLI did not report subtype=success for /usage")
        }
        guard let result = root["result"] as? String, !result.isEmpty else {
            throw UsageError.schemaChanged("Missing result text")
        }

        let session = try window(
            in: result,
            matching: Line.session,
            kind: .session,
            group: .session,
            label: "Current session",
            // The five-hour window is anchored to first use, so between one ending and
            // the next starting there is no reset to report. See `Line.session`.
            requiresResetTime: false,
            timeZone: timeZone,
            now: now
        )
        let weekly = try window(
            in: result,
            matching: Line.weekly,
            kind: .weeklyAll,
            group: .weekly,
            label: "Current week (all models)",
            // Always running, so a missing reset here is drift, not a state.
            requiresResetTime: true,
            timeZone: timeZone,
            now: now
        )

        // The staleness guard. `/usage` can answer from Claude Code's local cache when
        // it cannot reach the server, and the text carries no as-of time — so a stale
        // reading is indistinguishable from a fresh one by inspection. Command duration
        // is not a network signal; live and offline observations overlap.
        //
        // The reset time is the one usable handle. It arrives as part of the cached
        // payload, so a reading from a previous window carries that previous window's
        // reset time. Once it is behind us, the figure describes a window that has
        // already rolled over and the real current usage is unknown.
        //
        // Every required figure needs its own guard. A current session window does not
        // make a weekly figure from an already-ended window trustworthy.
        //
        // What this does not catch: staleness *within* a current window. The session
        // reset remains the shortest practical bound on a whole cached answer.
        for window in [session, weekly] {
            if let resetsAt = window.resetsAt,
               resetsAt.addingTimeInterval(resetGrace) < now {
                throw UsageError.claudeUsageOutdated(resetsAt: resetsAt)
            }
        }

        return UsageSnapshot(
            provider: .claude,
            sourcePath: .claudeCodeCLI,
            windows: [session, weekly],
            fetchedAt: now,
            sourceVersion: ProviderMetadataText.normalizedDisplay(sourceVersion)
        )
    }

    // MARK: - Line parsing

    /// Computed rather than stored: `Regex` is not `Sendable`, so a `static let` would
    /// be shared mutable state. Building one per parse costs nothing measurable here.
    private enum Line {
        /// `Current session: 88% used · resets Aug 25 at 1am (Asia/Taipei)`, or
        /// `Current session: 0% used` when no session window is running.
        ///
        /// The reset clause is optional because the five-hour window is anchored to
        /// first use, not to the clock: it starts when you next use Claude Code after
        /// the previous one ended (observed 2026-08-25: one window ended 22:09, the
        /// next ended 03:19 — five hours and ten minutes apart). Between the two there
        /// is no running window, so there is no reset to report and the CLI prints the
        /// percentage alone.
        ///
        /// Requiring the clause treated that ordinary state as schema drift, and the
        /// app sat on 過期 through every gap between finishing for the night and
        /// starting again.
        static var session: some RegexComponent<(Substring, Substring, Substring?)> {
            /Current session: (\d{1,3})% used(?: · resets (.+))?/
        }
        /// `Current week (all models): 8% used · resets Aug 31 at 12pm (Asia/Taipei)`
        ///
        /// Same shape so both can share one parser, but the reset is *required* here:
        /// the weekly window is always running, so a missing reset is real drift rather
        /// than a state this build should accept. See `requiresResetTime`.
        static var weekly: some RegexComponent<(Substring, Substring, Substring?)> {
            /Current week \(all models\): (\d{1,3})% used(?: · resets (.+))?/
        }
    }

    private static func window(
        in result: String,
        matching regex: some RegexComponent<(Substring, Substring, Substring?)>,
        kind: UsageWindow.Kind,
        group: UsageWindow.Group,
        label: String,
        requiresResetTime: Bool,
        timeZone: TimeZone,
        now: Date
    ) throws -> UsageWindow {
        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let matches = lines.compactMap { $0.wholeMatch(of: regex) }

        guard let match = matches.first else {
            // "The line is absent" and "the line is there but this build cannot read it"
            // need different messages, because they point at different problems. The
            // first version reported both as missing, and when the session line dropped
            // its reset clause the error read "Missing the Current session line" about a
            // line that was plainly present — which sent the diagnosis in the wrong
            // direction. This message is the only diagnostic a user can forward.
            let isPresent = lines.contains { $0.hasPrefix("\(label):") }
            throw UsageError.schemaChanged(
                isPresent ? "Unreadable \"\(label)\" line" : "Missing the \"\(label)\" line"
            )
        }
        // Two lines claiming the same window means the format is not what this build
        // reads. Picking one would be a coin flip on which number the user sees.
        guard matches.count == 1 else {
            throw UsageError.schemaChanged("Found \(matches.count) \"\(label)\" lines")
        }

        guard let percent = Int(match.1) else {
            throw UsageError.schemaChanged("Unreadable percentage in \"\(label)\"")
        }
        // The observed format reports 0–100. A larger figure means this build is reading
        // something other than a percentage, so it fails rather than clamping — clamping
        // would turn a misread into a confident 100%.
        guard percent <= 100 else {
            throw UsageError.schemaChanged("Percentage \(percent) is out of range in \"\(label)\"")
        }

        // An absent session reset is accepted only in the exact observed gap shape:
        // the CLI explicitly reports 0%, so there is no current usage figure whose
        // freshness would become unbounded. A nonzero percentage without a reset is
        // incomplete data, not permission to skip the staleness guard.
        //
        // The cost is that a `nil` reset cannot bound staleness. In this state that is
        // acceptable — the CLI is asserting 0%, not omitting a figure. The residual
        // exposure is narrow:
        // offline, with a cache captured during a gap, after a new window has since
        // started. Recorded in SAFETY.md rather than hidden.
        var resetsAt: Date?
        if let rawResetTime = match.2 {
            guard let parsed = parseResetTime(String(rawResetTime), timeZone: timeZone, now: now) else {
                throw UsageError.schemaChanged("Unreadable reset time in \"\(label)\"")
            }
            resetsAt = parsed
        } else if requiresResetTime {
            throw UsageError.schemaChanged("Missing reset time in \"\(label)\"")
        } else if percent != 0 {
            throw UsageError.schemaChanged("Missing reset time for nonzero \"\(label)\"")
        }

        return UsageWindow(
            kind: kind,
            group: group,
            used: UsedPercent(hundredScale: Double(percent)),
            resetsAt: resetsAt,
            // The text does not say which limit is currently binding, and guessing from
            // the higher percentage would put a "binding" badge on an inference.
            isActive: false
        )
    }

    // MARK: - Reset time

    /// `Aug 25 at 1am (Asia/Taipei)`, `Aug 25 at 12:59am (Asia/Taipei)`,
    /// `Aug 31 at 12pm (America/New_York)`.
    ///
    /// Minutes are optional — both forms are confirmed in real output — and the year is
    /// absent entirely, so it is inferred as whichever candidate lands nearest `now`.
    /// That is what makes a 31 Dec → 1 Jan reset resolve correctly instead of jumping
    /// eleven months backwards.
    static func parseResetTime(_ text: String, timeZone: TimeZone, now: Date) -> Date? {
        let pattern = /([A-Z][a-z]{2}) (\d{1,2}) at (\d{1,2})(?::(\d{2}))?(am|pm) \(([^)]+)\)/
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else {
            return nil
        }

        guard let month = monthNumbers[String(match.1)] else { return nil }
        guard let day = Int(match.2), (1...31).contains(day) else { return nil }
        guard let rawHour = Int(match.3), (1...12).contains(rawHour) else { return nil }

        let minute = match.4.flatMap { Int($0) } ?? 0
        guard (0...59).contains(minute) else { return nil }

        // 12am is midnight and 12pm is noon — the two cases a naive `+12` gets wrong.
        let isAfternoon = match.5 == "pm"
        let hour = switch (rawHour, isAfternoon) {
        case (12, false): 0
        case (12, true): 12
        case (let value, false): value
        case (let value, true): value + 12
        }

        // The CLI names the zone it rendered the time in. Trusting the local zone
        // instead would silently shift every reset for anyone travelling or running a
        // machine set to a different zone from their account. An unknown named zone is
        // therefore a schema change, not permission to guess.
        guard let resolvedZone = TimeZone(identifier: String(match.6)) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedZone
        let nowYear = calendar.component(.year, from: now)

        var components = DateComponents()
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = resolvedZone

        return [nowYear, nowYear + 1, nowYear - 1]
            .compactMap { year -> Date? in
                var candidate = components
                candidate.year = year
                return calendar.date(from: candidate)
            }
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    /// Fixed rather than read from `DateFormatter`, so the parse does not depend on the
    /// process locale — the same reason the child process runs with `LC_ALL` pinned.
    static let monthNumbers: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]
}
