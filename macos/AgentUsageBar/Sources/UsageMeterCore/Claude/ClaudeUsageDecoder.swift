import Foundation

/// Decodes the output of the one fixed `/usage` command.
///
/// # What the document contains
///
/// With `--verbose`, `--output-format json` prints one JSON array holding every message
/// of the run. Three things in it matter:
///
/// - the final `result` message, the only place the CLI reports success;
/// - `usage_report`, a structured copy of the usage figures, attached to the assistant
///   message that delivered `/usage`;
/// - the `result` text, the same figures as English prose.
///
/// Nothing else is read. The opening message names the working directory, the session,
/// and every tool and command of the run; the text carries the user's private
/// local-activity breakdown. None of that is parsed, stored, logged, or quoted in an
/// error.
///
/// # Why the report is preferred to the prose
///
/// The prose is written for a person and can change shape; the report has fields. More
/// importantly, the two disagree about a failed lookup. When Claude Code cannot reach
/// the usage service, the prose still prints the last figures it knew, with nothing to
/// mark them as old. The report says so instead: its rows are `null`. Observed
/// 2026-10-11 against Claude Code 2.1.287 with the network blocked — prose present,
/// rows `null`, and the prose figures older than a reading taken moments before.
///
/// Rows are not proof of a lookup made by this very run. In the same observation, a
/// blocked run three seconds after a live one returned that live run's rows unchanged,
/// and one forty seconds after returned `null`. So rows mean an answer from the server
/// within about the last minute: Claude Code briefly reuses a fresh one, for a length
/// it does not document. That is a far tighter bound than the prose offers, not a
/// timestamp.
///
/// So three cases are kept apart:
///
/// | The document has | This build |
/// |---|---|
/// | no report | reads the prose: an older CLI, or a sign-in the report is not offered for |
/// | a report with no rows | fails with `claudeUsageUnavailable`; the prose is **not** consulted |
/// | a report with rows | reads the rows |
///
/// The middle case is the point. Falling back to the prose there would turn "the lookup
/// failed" back into a confident number, which is the exact failure the report exists
/// to prevent.
///
/// The report is documented as experimental, so its absence is never an error and the
/// two rows this app depends on are read strictly. See `ClaudeUsageReportDecoder`.
public enum ClaudeUsageDecoder {

    public static func decode(
        _ data: Data,
        now: Date,
        sourceVersion: String? = nil,
        timeZone: TimeZone = .current
    ) throws -> UsageSnapshot {
        let output = try Output(data)

        // `is_error` absent is treated as an error rather than as success: a missing
        // success signal is not the same thing as a success signal.
        guard output.result["is_error"] as? Bool == false else {
            throw UsageError.claudeCommandFailed("The CLI reported is_error for /usage")
        }
        guard let subtype = output.result["subtype"] as? String, subtype == "success" else {
            throw UsageError.claudeCommandFailed("The CLI did not report subtype=success for /usage")
        }

        let windows: [UsageWindow]
        if let rows = try output.reportRows(),
           let reported = try ClaudeUsageReportDecoder.windows(from: rows, now: now) {
            windows = reported
        } else {
            // Either no report was attached, or it has rows but not both meters this
            // app is built on. In the second case the server did answer, so the prose
            // beside it is as fresh as the rows are.
            windows = try proseWindows(in: output.result, timeZone: timeZone, now: now)
        }

        // The staleness guard. The prose can come from Claude Code's local cache and
        // carries no as-of time, so a stale reading is indistinguishable from a fresh
        // one by inspection; command duration is not a network signal either, because
        // live and offline observations overlap.
        //
        // The reset time is the one usable handle. It arrives as part of the cached
        // payload, so a reading from a previous window carries that previous window's
        // reset time. Once it is behind us, the figure describes a window that has
        // already rolled over and the real current usage is unknown.
        //
        // The guard stays for report rows too. Rows have only been seen to be at most
        // moments old, but that is an observation of one CLI version, not a contract,
        // and the check costs nothing when it passes.
        //
        // Each required figure needs its own guard: a current session window does not
        // make a weekly figure from an already-ended window trustworthy. What this does
        // not catch is staleness *within* a current window.
        for window in windows where window.kind == .session || window.kind == .weeklyAll {
            if let resetsAt = window.resetsAt,
               resetsAt.addingTimeInterval(ClaudeUsageTextDecoder.resetGrace) < now {
                throw UsageError.claudeUsageOutdated(resetsAt: resetsAt)
            }
        }

        return UsageSnapshot(
            provider: .claude,
            sourcePath: .claudeCodeCLI,
            windows: windows,
            fetchedAt: now,
            sourceVersion: ProviderMetadataText.normalizedDisplay(sourceVersion)
        )
    }

    private static func proseWindows(
        in result: [String: Any],
        timeZone: TimeZone,
        now: Date
    ) throws -> [UsageWindow] {
        guard let text = result["result"] as? String, !text.isEmpty else {
            throw UsageError.schemaChanged("Missing result text")
        }
        return try ClaudeUsageTextDecoder.windows(in: text, timeZone: timeZone, now: now)
    }

    /// The parts of the document this build reads, and nothing else.
    private struct Output {
        /// The final `result` message.
        let result: [String: Any]
        /// `usage_report`, when the CLI attached one. `nil` means it did not.
        let report: [String: Any]?

        init(_ data: Data) throws {
            let root = try? JSONSerialization.jsonObject(with: data)

            if let envelope = root as? [String: Any] {
                // What the CLI prints without `--verbose`: the result message alone,
                // with no report to find.
                result = envelope
                report = nil
                return
            }
            guard let messages = root as? [Any] else {
                throw UsageError.schemaChanged("Command output is not a JSON object")
            }
            let objects = messages.compactMap { $0 as? [String: Any] }

            let results = objects.filter { $0["type"] as? String == "result" }
            guard let result = results.first else {
                throw UsageError.schemaChanged("Command output has no result message")
            }
            // Two messages claiming to be the outcome means the document is not what
            // this build reads. Picking one would be a coin flip on which the user sees.
            guard results.count == 1 else {
                throw UsageError.schemaChanged("Found \(results.count) result messages")
            }
            self.result = result

            let reports = objects
                .filter { $0["type"] as? String == "assistant" }
                .compactMap { message -> Any? in
                    guard let value = message["usage_report"], !(value is NSNull) else { return nil }
                    return value
                }
            guard reports.count <= 1 else {
                throw UsageError.schemaChanged("Found \(reports.count) usage reports")
            }
            guard let attached = reports.first else {
                report = nil
                return
            }
            guard let report = attached as? [String: Any] else {
                throw UsageError.schemaChanged("Unreadable usage report")
            }
            self.report = report
        }

        /// - Returns: the report's rows, or `nil` when no report was attached.
        /// - Throws: `claudeUsageUnavailable` when a report is attached but holds no
        ///   figure from the server.
        func reportRows() throws -> [Any]? {
            guard let report else { return nil }

            // `rate_limits` is `null` when Claude Code could not get the plan's usage,
            // and `limits` is `null` when it has no rows to report. Both say the same
            // thing here: this document holds no figure from the server. A key that is
            // missing altogether is something else — the report has changed shape.
            guard let rateLimits = report["rate_limits"] else {
                throw UsageError.schemaChanged("Unreadable usage report")
            }
            if rateLimits is NSNull { throw UsageError.claudeUsageUnavailable }
            guard let limits = (rateLimits as? [String: Any])?["limits"] else {
                throw UsageError.schemaChanged("Unreadable usage report")
            }
            if limits is NSNull { throw UsageError.claudeUsageUnavailable }
            guard let rows = limits as? [Any] else {
                throw UsageError.schemaChanged("Unreadable usage report")
            }
            // An empty list is the server reporting that no meter applies. That is not
            // a state this app can draw, and it is not a reason to trust the prose.
            guard !rows.isEmpty else {
                throw UsageError.schemaChanged("The usage report contains no limit rows")
            }
            return rows
        }
    }
}
