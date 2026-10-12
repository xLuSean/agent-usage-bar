import Foundation
import Testing
@testable import UsageMeterCore

/// The structured `usage_report` path, and the rule that decides between it and the
/// prose.
///
/// All content is synthetic: neutral percentages, an invented model name, and none of
/// what the real document carries beside the figures — the working directory and tool
/// list in the opening message, the local-activity breakdown in the text.
struct ClaudeUsageReportDecoderTests {

    // MARK: - Helpers

    /// 2026-08-24 13:00:00 UTC, the instant the prose tests use.
    static let now = Date(timeIntervalSince1970: 1_787_576_400)
    static let taipei = TimeZone(identifier: "Asia/Taipei")!

    /// Four hours and seven days after `now`, in the two timestamp shapes the report
    /// has been seen to use: with six fractional digits, and with none.
    static let sessionReset = "2026-08-24T17:00:00.139208+00:00"
    static let weeklyReset = "2026-08-31T04:00:00+00:00"

    static func row(
        kind: String,
        group: String? = nil,
        percent: Any = 42,
        resetsAt: Any? = sessionReset,
        isActive: Any? = false,
        model: String? = nil,
        surface: String? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "kind": kind,
            "group": group ?? (kind == "session" ? "session" : "weekly"),
            "percent": percent,
            "resets_at": resetsAt ?? NSNull(),
            // Present in real rows and deliberately never read.
            "severity": "critical",
        ]
        if let isActive { row["is_active"] = isActive }
        if model != nil || surface != nil {
            row["scope"] = [
                "model": model.map { ["display_name": $0] as Any } ?? NSNull(),
                "surface": surface.map { ["display_name": $0] as Any } ?? NSNull(),
            ]
        } else {
            row["scope"] = NSNull()
        }
        return row
    }

    static var session: [String: Any] { row(kind: "session", percent: 42, resetsAt: sessionReset) }
    static var weekly: [String: Any] {
        row(kind: "weekly_all", percent: 7, resetsAt: weeklyReset, isActive: true)
    }
    static var scoped: [String: Any] {
        row(kind: "weekly_scoped", percent: 3, resetsAt: weeklyReset, model: "Example Model")
    }

    /// The prose the same run would print. Its figures differ from the rows on purpose,
    /// so a test can tell which of the two was read.
    static let prose = ClaudeUsageTextDecoderTests.body(
        session: "88% used · resets Aug 25 at 1am (Asia/Taipei)",
        weekly: "66% used · resets Aug 31 at 12pm (Asia/Taipei)"
    )

    /// The array `--output-format json --verbose` prints: an opening message, the
    /// assistant message that delivers `/usage`, and the final result.
    static func output(
        report: Any? = nil,
        result: String = prose,
        isError: Bool = false,
        extraMessages: [[String: Any]] = []
    ) -> Data {
        var assistant: [String: Any] = [
            "type": "assistant",
            "session_id": "00000000-0000-0000-0000-000000000000",
            "local_command_source": "<local-command-stdout>private-activity-marker</local-command-stdout>",
        ]
        if let report { assistant["usage_report"] = report }

        let messages: [[String: Any]] = [
            [
                "type": "system",
                "subtype": "init",
                "cwd": "/Users/private-path-marker",
                "tools": ["authentication-helper", "unknown option probe"],
            ],
            assistant,
        ] + extraMessages + [
            [
                "type": "result",
                "subtype": "success",
                "is_error": isError,
                "result": result,
                "num_turns": 0,
                "total_cost_usd": 0,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: messages)
    }

    static func report(limits: Any) -> [String: Any] {
        [
            "session": ["total_cost_usd": 0],
            "rate_limits": [
                "limits": limits,
                // Present in real reports and deliberately never read.
                "extra_usage": ["is_enabled": true, "utilization": 0.5],
            ] as [String: Any],
        ]
    }

    static func decode(_ data: Data, now: Date = now) throws -> UsageSnapshot {
        try ClaudeUsageDecoder.decode(data, now: now, timeZone: taipei)
    }

    static func decode(rows: [[String: Any]], now: Date = now) throws -> UsageSnapshot {
        try decode(output(report: report(limits: rows)), now: now)
    }

    // MARK: - Reading the rows

    @Test func decodesTheReportRows() throws {
        let snapshot = try Self.decode(rows: [Self.session, Self.weekly, Self.scoped])

        #expect(snapshot.provider == .claude)
        #expect(snapshot.sourcePath == .claudeCodeCLI)
        #expect(snapshot.fetchedAt == Self.now)
        #expect(snapshot.windows.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])

        let session = try #require(snapshot.windows.first { $0.kind == .session })
        #expect(session.used.usedPercent == 42)
        #expect(session.group == .session)
        #expect(session.isActive == false)
        // The fractional seconds are part of the instant, not a reason to reject it.
        let sessionReset = try #require(session.resetsAt).timeIntervalSince1970
        #expect(abs(sessionReset - 1_787_590_800.139) < 0.01)

        let weekly = try #require(snapshot.windows.first { $0.kind == .weeklyAll })
        #expect(weekly.used.usedPercent == 7)
        #expect(weekly.group == .weekly)
        #expect(weekly.isActive)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_788_148_800))

        let scoped = try #require(snapshot.windows.first { $0.kind == .weeklyScoped })
        #expect(scoped.used.usedPercent == 3)
        #expect(scoped.modelDisplayName == "Example Model")
        #expect(scoped.displayName == "7 days · Example Model")
    }

    /// The rows and the prose describe the same account, and when both are present the
    /// rows win. The prose here would read 88% and 66%.
    @Test func prefersTheReportToTheProse() throws {
        let snapshot = try Self.decode(rows: [Self.session, Self.weekly])
        #expect(snapshot.representativeWindow?.used.usedPercent == 42)
        #expect(snapshot.windows.first { $0.kind == .weeklyAll }?.used.usedPercent == 7)
    }

    /// The server's order is not the display order, and must not decide which row is
    /// taken for which meter.
    @Test func findsTheRequiredRowsInAnyOrder() throws {
        let snapshot = try Self.decode(rows: [Self.scoped, Self.weekly, Self.session])
        #expect(snapshot.windows.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])
        #expect(snapshot.representativeWindow?.used.usedPercent == 42)
    }

    @Test func acceptsFractionalPercentages() throws {
        let snapshot = try Self.decode(rows: [
            Self.row(kind: "session", percent: 23.5),
            Self.weekly,
        ])
        #expect(snapshot.representativeWindow?.used.usedPercent == 24)
    }

    @Test(arguments: [0, 1, 99, 100])
    func acceptsThePercentageRange(_ percent: Int) throws {
        let snapshot = try Self.decode(rows: [Self.row(kind: "session", percent: percent), Self.weekly])
        #expect(snapshot.representativeWindow?.used.usedPercent == percent)
    }

    /// Reports from before the field was guaranteed can omit it. Absent is not `true`.
    @Test func treatsAMissingBindingFlagAsNotBinding() throws {
        let snapshot = try Self.decode(rows: [
            Self.row(kind: "session", isActive: nil),
            Self.row(kind: "weekly_all", resetsAt: Self.weeklyReset, isActive: NSNull()),
        ])
        #expect(snapshot.windows.allSatisfy { $0.isActive == false })
    }

    /// JSON `1` is not JSON `true`, and only the latter is the server saying so.
    @Test func doesNotReadANumberAsTheBindingFlag() throws {
        let snapshot = try Self.decode(rows: [
            Self.row(kind: "session", isActive: 1),
            Self.weekly,
        ])
        #expect(snapshot.windows.first { $0.kind == .session }?.isActive == false)
    }

    // MARK: - Choosing between the report and the prose

    /// The case the report exists for. Claude Code could not reach the usage service:
    /// the rows are `null`, and the prose still prints the last figures it knew. Those
    /// figures must not be shown.
    @Test(arguments: ["limits", "rate_limits"])
    func neverFallsBackToTheProseWhenTheReportHasNoRows(_ nullField: String) {
        let report: [String: Any] = nullField == "limits"
            ? Self.report(limits: NSNull())
            : ["session": [:] as [String: Any], "rate_limits": NSNull()]

        #expect(throws: UsageError.claudeUsageUnavailable) {
            try Self.decode(Self.output(report: report))
        }
    }

    /// An older CLI, or a sign-in the report is not offered for: the prose is all there
    /// is, and it is read exactly as before.
    @Test func readsTheProseWhenNoReportIsAttached() throws {
        let snapshot = try Self.decode(Self.output(report: nil))
        #expect(snapshot.windows.map(\.kind) == [.session, .weeklyAll])
        #expect(snapshot.representativeWindow?.used.usedPercent == 88)
    }

    /// A `null` report is no report. It is not the same statement as a report whose rows
    /// are `null`.
    @Test func treatsANullReportAsNoReport() throws {
        let snapshot = try Self.decode(Self.output(report: NSNull()))
        #expect(snapshot.representativeWindow?.used.usedPercent == 88)
    }

    /// What the CLI prints without `--verbose`: the result message alone.
    @Test func stillReadsTheSingleObjectForm() throws {
        let snapshot = try Self.decode(ClaudeUsageTextDecoderTests.envelope(Self.prose))
        #expect(snapshot.representativeWindow?.used.usedPercent == 88)
    }

    /// Not yet observed: between two session windows the prose prints `0%` with no
    /// reset, and the rows might instead leave the session meter out altogether. The
    /// server answered either way, so the prose is fresh and is read, rather than the
    /// app sitting on an error through every idle gap.
    @Test func readsTheProseWhenARequiredRowIsAbsent() throws {
        let prose = ClaudeUsageTextDecoderTests.body(session: "0% used")
        let snapshot = try Self.decode(
            Self.output(report: Self.report(limits: [Self.weekly, Self.scoped]), result: prose)
        )

        #expect(snapshot.windows.map(\.kind) == [.session, .weeklyAll])
        #expect(snapshot.representativeWindow?.used.usedPercent == 0)
        #expect(snapshot.representativeWindow?.resetsAt == nil)
    }

    /// The prose is still read strictly when it is the fallback.
    @Test func failsWhenARequiredRowIsAbsentAndTheProseCannotBeRead() {
        #expect(throws: UsageError.schemaChanged("Missing result text")) {
            try Self.decode(Self.output(report: Self.report(limits: [Self.weekly]), result: ""))
        }
    }

    // MARK: - The two required rows fail closed

    @Test func acceptsAZeroSessionWithNoReset() throws {
        let snapshot = try Self.decode(rows: [
            Self.row(kind: "session", percent: 0, resetsAt: nil),
            Self.weekly,
        ])
        #expect(snapshot.representativeWindow?.used.usedPercent == 0)
        #expect(snapshot.representativeWindow?.resetsAt == nil)
    }

    @Test func rejectsANonzeroSessionWithNoReset() {
        #expect(throws: UsageError.schemaChanged("Missing reset time in the \"session\" usage row")) {
            try Self.decode(rows: [Self.row(kind: "session", percent: 12, resetsAt: nil), Self.weekly])
        }
    }

    /// The weekly window is always running, so its reset is never legitimately absent —
    /// not even at zero.
    @Test func rejectsAWeeklyRowWithNoReset() {
        #expect(throws: UsageError.schemaChanged("Missing reset time in the \"weekly_all\" usage row")) {
            try Self.decode(rows: [
                Self.session,
                Self.row(kind: "weekly_all", percent: 0, resetsAt: nil),
            ])
        }
    }

    @Test(arguments: ["Aug 25 at 1am (Asia/Taipei)", "2026-08-24", "", "tomorrow"])
    func rejectsAnUnreadableResetTime(_ text: String) {
        #expect(throws: UsageError.schemaChanged("Unreadable reset time in the \"session\" usage row")) {
            try Self.decode(rows: [Self.row(kind: "session", resetsAt: text), Self.weekly])
        }
    }

    @Test func rejectsAResetTimeThatIsNotText() {
        #expect(throws: UsageError.schemaChanged("Unreadable reset time in the \"weekly_all\" usage row")) {
            try Self.decode(rows: [
                Self.session,
                Self.row(kind: "weekly_all", resetsAt: 1_788_148_800),
            ])
        }
    }

    /// Out of range is unreadable, not clamped: clamping would turn a misread into a
    /// confident 100%. `true` is here because JSON booleans arrive as numbers.
    @Test func rejectsAnythingThatIsNotAPercentage() {
        let invalid: [Any] = [101, -1, 250.5, "42", true, NSNull(), ["value": 42]]
        for percent in invalid {
            #expect(throws: UsageError.schemaChanged("Unreadable percentage in the \"session\" usage row")) {
                try Self.decode(rows: [Self.row(kind: "session", percent: percent), Self.weekly])
            }
        }
    }

    /// Two rows claiming the same meter: picking one would be a coin flip on which
    /// number the user sees.
    @Test func rejectsDuplicateRequiredRows() {
        #expect(throws: UsageError.schemaChanged("Found 2 \"session\" usage rows")) {
            try Self.decode(rows: [Self.session, Self.row(kind: "session", percent: 9), Self.weekly])
        }
        #expect(throws: UsageError.schemaChanged("Found 2 \"weekly_all\" usage rows")) {
            try Self.decode(rows: [Self.session, Self.weekly, Self.weekly])
        }
    }

    /// A malformed weekly row is reported as malformed even when the session row is
    /// also missing, rather than sending the reading off to the prose.
    @Test func reportsAMalformedRequiredRowBeforeFallingBack() {
        #expect(throws: UsageError.schemaChanged("Unreadable percentage in the \"weekly_all\" usage row")) {
            try Self.decode(rows: [Self.row(kind: "weekly_all", percent: "7", resetsAt: Self.weeklyReset)])
        }
    }

    @Test func rejectsAReportWithNoRowsAtAll() {
        #expect(throws: UsageError.schemaChanged("The usage report contains no limit rows")) {
            try Self.decode(rows: [])
        }
    }

    @Test func rejectsAReportOfTheWrongShape() {
        let malformed: [Any] = [
            "rows",
            ["session": [:] as [String: Any]],
            ["rate_limits": ["rows": []] as [String: Any]],
            ["rate_limits": ["limits": "none"] as [String: Any]],
            ["rate_limits": "unavailable"],
        ]
        for report in malformed {
            #expect(throws: UsageError.schemaChanged("Unreadable usage report")) {
                try Self.decode(Self.output(report: report))
            }
        }
    }

    // MARK: - Every other row is best effort

    /// A row this build cannot read is left out. It must not take the two required
    /// figures with it.
    @Test func leavesOutUnreadableAdditionalRows() throws {
        let unreadable: [[String: Any]] = [
            Self.row(kind: "weekly_scoped", percent: 120, resetsAt: Self.weeklyReset, model: "Out Of Range"),
            Self.row(kind: "weekly_scoped", percent: "9", resetsAt: Self.weeklyReset, model: "Not A Number"),
            Self.row(kind: "weekly_scoped", percent: 9, resetsAt: "soon", model: "Bad Reset"),
            Self.row(kind: "weekly scoped!", percent: 9, resetsAt: Self.weeklyReset, model: "Bad Kind"),
            Self.row(kind: "weekly_scoped", group: "weekly\u{202E}", percent: 9, resetsAt: Self.weeklyReset, model: "Bad Group"),
            ["percent": 9],
        ]
        let snapshot = try Self.decode(rows: [Self.session, Self.weekly] + unreadable + [Self.scoped])

        #expect(snapshot.windows.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])
        #expect(snapshot.windows.last?.modelDisplayName == "Example Model")
    }

    /// An additional row whose window has already ended describes nothing current. It
    /// is dropped; the reading it came with is not.
    @Test func leavesOutAnAdditionalRowPastItsReset() throws {
        let ended = Self.row(
            kind: "weekly_scoped", percent: 80, resetsAt: "2026-08-24T12:00:00+00:00", model: "Ended"
        )
        let snapshot = try Self.decode(rows: [Self.session, Self.weekly, ended])
        #expect(snapshot.windows.map(\.kind) == [.session, .weeklyAll])
    }

    /// A kind this build has never seen is displayed, not discarded.
    @Test func keepsAnUnfamiliarKind() throws {
        let unfamiliar = Self.row(
            kind: "monthly_all", group: "monthly", percent: 29, resetsAt: Self.weeklyReset
        )
        let snapshot = try Self.decode(rows: [Self.session, Self.weekly, unfamiliar])

        let window = try #require(snapshot.windows.last)
        #expect(window.kind == .unrecognized("monthly_all"))
        #expect(window.group == .unrecognized("monthly"))
        #expect(window.used.usedPercent == 29)
    }

    /// Identity is kind plus label. Two rows with one identity cannot both be shown, and
    /// choosing between them would be a guess — so neither is.
    @Test func leavesOutAdditionalRowsThatShareAnIdentity() throws {
        let snapshot = try Self.decode(rows: [
            Self.session, Self.weekly, Self.scoped,
            Self.row(kind: "weekly_scoped", percent: 50, resetsAt: Self.weeklyReset, model: "Twin"),
            Self.row(kind: "weekly_scoped", percent: 60, resetsAt: Self.weeklyReset, model: "Twin"),
        ])
        #expect(snapshot.windows.compactMap(\.modelDisplayName) == ["Example Model"])
        #expect(Set(snapshot.windows.map(\.id)).count == snapshot.windows.count)
    }

    @Test func labelsARowScopedToASurface() throws {
        let snapshot = try Self.decode(rows: [
            Self.session, Self.weekly,
            Self.row(kind: "weekly_scoped", percent: 5, resetsAt: Self.weeklyReset, surface: "Example Surface"),
        ])
        #expect(snapshot.windows.last?.modelDisplayName == "Example Surface")
    }

    /// The label is provider text. One that is not safe to display is not displayed; the
    /// row keeps its figure and falls back to the generic name.
    @Test func dropsAnUnsafeLabelButKeepsTheRow() throws {
        let snapshot = try Self.decode(rows: [
            Self.session, Self.weekly,
            Self.row(kind: "weekly_scoped", percent: 5, resetsAt: Self.weeklyReset, model: "Evil\u{202E}Name"),
        ])
        let window = try #require(snapshot.windows.last)
        #expect(window.modelDisplayName == nil)
        #expect(window.used.usedPercent == 5)
        #expect(window.displayName == "7 days · per model")
    }

    @Test func boundsTheNumberOfAdditionalRows() throws {
        let many = (0..<40).map {
            Self.row(kind: "weekly_scoped", percent: 1, resetsAt: Self.weeklyReset, model: "Model \($0)")
        }
        let snapshot = try Self.decode(rows: [Self.session, Self.weekly] + many)
        #expect(snapshot.windows.count == 2 + ClaudeUsageReportDecoder.maximumAdditionalRows)
    }

    // MARK: - Staleness

    /// Rows have only been seen to be at most moments old, but that is an observation,
    /// not a contract. A required row past its reset is still refused.
    @Test func rejectsARequiredRowPastItsReset() {
        let later = Date(timeIntervalSince1970: 1_787_590_800 + 3_600)
        do {
            _ = try Self.decode(rows: [Self.session, Self.weekly], now: later)
            Issue.record("A required row past its reset must not decode")
        } catch let error as UsageError {
            guard case .claudeUsageOutdated = error else {
                Issue.record("Expected claudeUsageOutdated, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    // MARK: - The envelope

    @Test func rejectsAnErrorResultEvenWithAReport() {
        #expect(throws: UsageError.claudeCommandFailed("The CLI reported is_error for /usage")) {
            try Self.decode(
                Self.output(report: Self.report(limits: [Self.session, Self.weekly]), isError: true)
            )
        }
    }

    @Test func rejectsAnArrayWithNoResultMessage() {
        let data = try! JSONSerialization.data(withJSONObject: [
            ["type": "system", "subtype": "init"],
            ["type": "assistant", "usage_report": Self.report(limits: [Self.session, Self.weekly])],
        ])
        #expect(throws: UsageError.schemaChanged("Command output has no result message")) {
            try Self.decode(data)
        }
    }

    @Test func rejectsTwoResultMessages() {
        let extra: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": "x"]
        #expect(throws: UsageError.schemaChanged("Found 2 result messages")) {
            try Self.decode(Self.output(report: nil, extraMessages: [extra]))
        }
    }

    @Test func rejectsTwoUsageReports() {
        let extra: [String: Any] = [
            "type": "assistant",
            "usage_report": Self.report(limits: [Self.session, Self.weekly]),
        ]
        #expect(throws: UsageError.schemaChanged("Found 2 usage reports")) {
            try Self.decode(
                Self.output(report: Self.report(limits: [Self.session, Self.weekly]), extraMessages: [extra])
            )
        }
    }

    /// A report belongs to the assistant message that delivered `/usage`. The same key
    /// on any other message is not one.
    @Test func ignoresAReportOnAMessageThatIsNotTheAssistants() throws {
        let stray: [String: Any] = ["type": "system", "usage_report": Self.report(limits: NSNull())]
        let snapshot = try Self.decode(Self.output(report: nil, extraMessages: [stray]))
        #expect(snapshot.representativeWindow?.used.usedPercent == 88)
    }

    // MARK: - Nothing private survives

    /// Every failure message is app-authored. Nothing the provider controls — a label,
    /// a kind, the working directory, the activity text — may reach one.
    @Test func errorsNeverCarryProviderControlledText() {
        let marker = "private-marker"
        let attempts: [Data] = [
            Self.output(report: Self.report(limits: [
                Self.row(kind: "session", percent: marker), Self.weekly,
            ])),
            Self.output(report: Self.report(limits: [
                Self.session, Self.row(kind: "weekly_all", resetsAt: marker),
            ])),
            Self.output(report: [marker: marker]),
            Self.output(report: Self.report(limits: NSNull()), result: marker),
            Self.output(report: nil, result: marker),
        ]
        for data in attempts {
            do {
                _ = try Self.decode(data)
                Issue.record("Expected a failure")
            } catch {
                let described = "\(error)"
                #expect(!described.contains(marker))
                #expect(!described.contains("private-path-marker"))
                #expect(!described.contains("private-activity-marker"))
            }
        }
    }

    /// Whatever the decoder accepts, the store must be willing to keep: a reading the
    /// store silently refused would be fetched again on every launch.
    @Test func whatIsDecodedCanBeStored() throws {
        let suite = "ClaudeUsageReportDecoderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageSnapshotStore(defaults: defaults)

        let shapes: [[[String: Any]]] = [
            [Self.session, Self.weekly, Self.scoped],
            [Self.row(kind: "session", percent: 0, resetsAt: nil), Self.weekly],
            [
                Self.session, Self.weekly,
                Self.row(kind: "monthly_all", group: "monthly", percent: 29, resetsAt: nil),
            ],
        ]
        for rows in shapes {
            let snapshot = try Self.decode(rows: rows)
            store.save(snapshot)
            #expect(store.load(.claude, now: snapshot.fetchedAt) == snapshot)
            store.clear(.claude)
        }
    }
}
