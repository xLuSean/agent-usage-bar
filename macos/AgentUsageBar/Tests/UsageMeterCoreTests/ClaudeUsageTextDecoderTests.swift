import Foundation
import Testing
@testable import UsageMeterCore

/// The figures live in English prose, not in a field. Every test here exists because
/// that prose could change shape, and the only acceptable response to prose this build
/// does not recognise is to report nothing.
///
/// All content is synthetic: neutral percentages, no session id, and none of the
/// local-activity breakdown the real command prints.
struct ClaudeUsageTextDecoderTests {

    // MARK: - Helpers

    /// Wraps body text in the envelope the CLI actually emits.
    static func envelope(
        _ result: String,
        isError: Bool = false,
        subtype: String = "success"
    ) -> Data {
        let object: [String: Any] = [
            "is_error": isError,
            "subtype": subtype,
            "result": result,
            // Present in real output and deliberately never read.
            "session_id": "00000000-0000-0000-0000-000000000000",
            "total_cost_usd": 0,
            "num_turns": 0,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func body(
        session: String = "42% used · resets Aug 25 at 1am (Asia/Taipei)",
        weekly: String = "7% used · resets Aug 31 at 12pm (Asia/Taipei)"
    ) -> String {
        """
        You are currently using your subscription to power your Claude Code usage

        Current session: \(session)
        Current week (all models): \(weekly)
        """
    }

    /// 2026-08-24 21:00 +08:00 — four hours before the Aug 25 01:00 reset used throughout.
    static let now = Date(timeIntervalSince1970: 1_787_576_400)
    static let taipei = TimeZone(identifier: "Asia/Taipei")!

    // MARK: - The happy path

    @Test func decodesBothWindows() throws {
        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(Self.body()),
            now: Self.now,
            timeZone: Self.taipei
        )

        #expect(snapshot.provider == .claude)
        #expect(snapshot.sourcePath == .claudeCodeCLI)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.representativeWindow?.kind == .session)
        #expect(snapshot.representativeWindow?.used.usedPercent == 42)
        #expect(snapshot.windows.first { $0.kind == .weeklyAll }?.used.usedPercent == 7)
    }

    /// The breakdown that follows the figures names skills, MCP servers, and request
    /// counts. It must neither break the parse nor survive it.
    @Test func ignoresTheLocalActivityBreakdown() throws {
        let text = Self.body() + """


        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine.

        Last 24h · 12 requests · 2 sessions
          40% of your usage was at >150k context
          Top skills: /example 30%
          Top MCP servers: Example 10%
        """

        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(text),
            now: Self.now,
            timeZone: Self.taipei
        )

        #expect(snapshot.representativeWindow?.used.usedPercent == 42)
    }

    @Test(arguments: [0, 1, 99, 100])
    func acceptsThePercentageRange(_ percent: Int) throws {
        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(Self.body(session: "\(percent)% used · resets Aug 25 at 1am (Asia/Taipei)")),
            now: Self.now,
            timeZone: Self.taipei
        )
        #expect(snapshot.representativeWindow?.used.usedPercent == percent)
    }

    // MARK: - Reset time formats

    /// Both forms occur in real output: minutes are printed only when non-zero.
    @Test func parsesResetWithAndWithoutMinutes() throws {
        let withMinutes = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 12:59am (Asia/Taipei)", timeZone: Self.taipei, now: Self.now
        )
        let withoutMinutes = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 1am (Asia/Taipei)", timeZone: Self.taipei, now: Self.now
        )

        #expect(withMinutes != nil)
        #expect(withoutMinutes != nil)
        // 00:59 and 01:00 on the same day, one minute apart.
        #expect(withoutMinutes!.timeIntervalSince(withMinutes!) == 60)
    }

    /// The two cases a naive "+12 for pm" gets backwards.
    @Test func mapsTwelveHourNoonAndMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.taipei

        let midnight = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 12am (Asia/Taipei)", timeZone: Self.taipei, now: Self.now
        )
        let noon = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 12pm (Asia/Taipei)", timeZone: Self.taipei, now: Self.now
        )

        #expect(calendar.component(.hour, from: midnight!) == 0)
        #expect(calendar.component(.hour, from: noon!) == 12)
    }

    /// The text carries no year. A 31 Dec reading read on 1 Jan must not resolve
    /// eleven months into the past.
    @Test func infersTheYearAcrossNewYear() throws {
        // 2027-01-01 00:30 +08:00
        let newYear = Date(timeIntervalSince1970: 1_798_734_600)
        let resets = ClaudeUsageTextDecoder.parseResetTime(
            "Dec 31 at 11pm (Asia/Taipei)", timeZone: Self.taipei, now: newYear
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.taipei
        #expect(calendar.component(.year, from: resets!) == 2026)
        #expect(abs(resets!.timeIntervalSince(newYear)) < 3 * 3_600)
    }

    /// The CLI names the zone it rendered in. Reading it in the machine's zone instead
    /// would shift every reset for anyone whose machine and account disagree.
    @Test func honoursTheNamedTimeZone() throws {
        let taipei = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 1am (Asia/Taipei)", timeZone: .gmt, now: Self.now
        )
        let newYork = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 1am (America/New_York)", timeZone: .gmt, now: Self.now
        )
        #expect(taipei != newYork)
    }

    /// A named zone is part of the CLI data, not a hint. Falling back to the machine's
    /// zone would turn a format change into a plausible but incorrect reset time.
    @Test func rejectsAnUnknownNamedTimeZone() {
        let reset = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 1am (Unknown/Fixture)", timeZone: Self.taipei, now: Self.now
        )
        #expect(reset == nil)
    }

    @Test(arguments: [
        "Aug 25 1am (Asia/Taipei)",          // missing "at"
        "Aug 25 at 1 (Asia/Taipei)",         // missing am/pm
        "Aug 25 at 13pm (Asia/Taipei)",      // not a 12-hour clock
        "Foo 25 at 1am (Asia/Taipei)",       // not a month
        "Aug 25 at 1am",                     // no zone
        "Aug 25 at 1:70am (Asia/Taipei)",    // impossible minute
    ])
    func rejectsMalformedResetTimes(_ text: String) {
        #expect(ClaudeUsageTextDecoder.parseResetTime(text, timeZone: Self.taipei, now: Self.now) == nil)
    }

    // MARK: - Failing closed

    @Test func rejectsAMissingSessionLine() {
        let text = "Current week (all models): 7% used · resets Aug 31 at 12pm (Asia/Taipei)"
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(Self.envelope(text), now: Self.now, timeZone: Self.taipei)
        }
    }

    @Test func rejectsAMissingWeeklyLine() {
        let text = "Current session: 42% used · resets Aug 25 at 1am (Asia/Taipei)"
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(Self.envelope(text), now: Self.now, timeZone: Self.taipei)
        }
    }

    /// Two lines claiming one window means this build is reading the wrong thing.
    /// Choosing between them would be a coin flip on the number the user sees.
    @Test func rejectsDuplicateWindows() {
        let text = Self.body() + "\nCurrent session: 91% used · resets Aug 25 at 1am (Asia/Taipei)"
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(Self.envelope(text), now: Self.now, timeZone: Self.taipei)
        }
    }

    /// Fails rather than clamping: clamping a misread to 100% is a confident wrong
    /// answer, and the whole point of this path is to never produce one.
    @Test func rejectsAnOutOfRangePercentage() {
        let text = Self.body(session: "420% used · resets Aug 25 at 1am (Asia/Taipei)")
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(Self.envelope(text), now: Self.now, timeZone: Self.taipei)
        }
    }

    @Test func rejectsNonJSONOutput() {
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Data("not json at all".utf8), now: Self.now, timeZone: Self.taipei
            )
        }
    }

    @Test func rejectsAnErrorEnvelope() {
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Self.envelope(Self.body(), isError: true), now: Self.now, timeZone: Self.taipei
            )
        }
    }

    @Test func rejectsANonSuccessSubtype() {
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Self.envelope(Self.body(), subtype: "error_during_execution"),
                now: Self.now,
                timeZone: Self.taipei
            )
        }
    }

    @Test func rejectsAnEmptyResult() {
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(Self.envelope(""), now: Self.now, timeZone: Self.taipei)
        }
    }

    @Test func malformedEnvelopeDoesNotExposeProviderControlledKeys() throws {
        let marker = "token-secret-marker"
        let data = try JSONSerialization.data(withJSONObject: [
            "is_error": false,
            "subtype": "success",
            marker: true,
        ])

        do {
            _ = try ClaudeUsageTextDecoder.decode(data, now: Self.now, timeZone: Self.taipei)
            Issue.record("Expected a schema error")
        } catch let error as UsageError {
            #expect(error.remedy?.contains(marker) == false)
            #expect(error.remedy(locale: Locale(identifier: "zh_Hant_TW"))?.contains(marker) == false)
        }
    }

    // MARK: - The staleness guard

    /// `/usage` answers from a local cache when it cannot reach the server, and the text
    /// carries no as-of time. A reading whose window has already ended describes a window
    /// that is over, so the current figure is unknown — and unknown is never drawn as 0%.
    @Test func rejectsAReadingPastItsResetTime() throws {
        // Two hours past the Aug 25 01:00 reset.
        let later = Self.now.addingTimeInterval(6 * 3_600)
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(Self.envelope(Self.body()), now: later, timeZone: Self.taipei)
        }
    }

    /// Both values come from the same cached answer. A current session reset cannot
    /// make a weekly value from an already-ended window trustworthy.
    @Test func rejectsWhenOnlyTheWeeklyWindowIsPastItsResetTime() {
        let text = Self.body(
            session: "42% used · resets Aug 25 at 1am (Asia/Taipei)",
            weekly: "7% used · resets Aug 24 at 8pm (Asia/Taipei)"
        )

        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Self.envelope(text), now: Self.now, timeZone: Self.taipei
            )
        }
    }

    @Test func reportsTheResetTimeItRejectedOn() throws {
        let later = Self.now.addingTimeInterval(6 * 3_600)
        do {
            _ = try ClaudeUsageTextDecoder.decode(Self.envelope(Self.body()), now: later, timeZone: Self.taipei)
            Issue.record("Expected an outdated-reading error")
        } catch let error as UsageError {
            guard case .claudeUsageOutdated(let resetsAt) = error else {
                Issue.record("Expected claudeUsageOutdated, got \(error)")
                return
            }
            #expect(resetsAt < later)
        }
    }

    /// The grace absorbs clock skew and the gap between the real boundary (00:59:59) and
    /// how the text renders it (1am). Without it the gauge flaps at every rollover.
    @Test func toleratesTheGraceWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.taipei
        let reset = ClaudeUsageTextDecoder.parseResetTime(
            "Aug 25 at 1am (Asia/Taipei)", timeZone: Self.taipei, now: Self.now
        )!

        let justInside = reset.addingTimeInterval(ClaudeUsageTextDecoder.resetGrace - 5)
        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(Self.body()), now: justInside, timeZone: Self.taipei
        )
        #expect(snapshot.representativeWindow?.used.usedPercent == 42)

        let justOutside = reset.addingTimeInterval(ClaudeUsageTextDecoder.resetGrace + 5)
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Self.envelope(Self.body()), now: justOutside, timeZone: Self.taipei
            )
        }
    }

    // MARK: - No running session window

    /// The five-hour window is anchored to first use, not to the clock, so between one
    /// ending and the next starting there is no window at all. The CLI then prints the
    /// session percentage with no reset clause.
    ///
    /// Observed live on 2026-08-25: the app failed four consecutive polls in that gap,
    /// reporting a missing line that was in fact present.
    @Test func acceptsASessionLineWithNoResetClause() throws {
        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(Self.body(session: "0% used")),
            now: Self.now,
            timeZone: Self.taipei
        )

        let session = try #require(snapshot.representativeWindow)
        #expect(session.kind == .session)
        #expect(session.used.usedPercent == 0)
        // Absent, not guessed: no window is running, so nothing is scheduled to reset.
        #expect(session.resetsAt == nil)
        // The weekly window still carries its own reset and is unaffected.
        #expect(snapshot.windows.first { $0.kind == .weeklyAll }?.resetsAt != nil)
    }

    /// The only observed reset-less session line explicitly reports 0%. Accepting a
    /// nonzero value without a reset would remove the session staleness bound while
    /// pretending the payload still represents the between-window state.
    @Test func rejectsANonzeroSessionLineWithNoResetClause() {
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Self.envelope(Self.body(session: "42% used")),
                now: Self.now,
                timeZone: Self.taipei
            )
        }
    }

    /// A `nil` reset must not be read as "reset time in the past". The staleness guard
    /// skips it, which is why the gap state resolves to a reading rather than 過期.
    @Test func aMissingSessionResetDoesNotTripTheStalenessGuard() throws {
        // Far enough ahead that any real reset in the fixture would already have passed.
        let muchLater = Self.now.addingTimeInterval(30 * 24 * 3_600)
        let weekly = "26% used · resets \(Self.resetText(muchLater.addingTimeInterval(3_600)))"

        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(Self.body(session: "0% used", weekly: weekly)),
            now: muchLater,
            timeZone: Self.taipei
        )
        #expect(snapshot.representativeWindow?.used.usedPercent == 0)
    }

    /// The weekly window is always running, so its reset disappearing is real drift
    /// rather than a state — the asymmetry with the session line is deliberate.
    @Test func stillRejectsAWeeklyLineWithNoResetClause() {
        #expect(throws: UsageError.self) {
            try ClaudeUsageTextDecoder.decode(
                Self.envelope(Self.body(weekly: "26% used")),
                now: Self.now,
                timeZone: Self.taipei
            )
        }
    }

    /// Regression for the shape captured from the real CLI during the gap. Synthetic
    /// percentages; the local-activity breakdown is deliberately absent.
    @Test func decodesTheObservedGapOutput() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 0% used
        Current week (all models): 26% used · resets Aug 31 at 11:59am (Asia/Taipei)
        """

        let snapshot = try ClaudeUsageTextDecoder.decode(
            Self.envelope(text), now: Self.now, timeZone: Self.taipei
        )
        #expect(snapshot.representativeWindow?.used.usedPercent == 0)
        #expect(snapshot.windows.first { $0.kind == .weeklyAll }?.used.usedPercent == 26)
    }

    // MARK: - Diagnostics

    /// "Absent" and "present but unreadable" point at different problems. Conflating
    /// them sent the live diagnosis in the wrong direction once already.
    @Test func distinguishesAnUnreadableLineFromAMissingOne() {
        func detail(for text: String) -> String? {
            do {
                _ = try ClaudeUsageTextDecoder.decode(
                    Self.envelope(text), now: Self.now, timeZone: Self.taipei
                )
                return nil
            } catch let error as UsageError {
                guard case .schemaChanged(let detail) = error else { return nil }
                return detail
            } catch {
                return nil
            }
        }

        let unreadable = detail(for: Self.body(session: "lots used · resets Aug 25 at 1am (Asia/Taipei)"))
        #expect(unreadable?.contains("Unreadable") == true)
        #expect(unreadable?.contains("Missing") == false)

        let missing = detail(for: "Current week (all models): 7% used · resets Aug 31 at 12pm (Asia/Taipei)")
        #expect(missing?.contains("Missing") == true)
    }

    /// Renders a date back into the CLI's own reset format, so a test can place a reset
    /// relative to `now` without hard-coding a calendar date.
    static func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = taipei
        formatter.dateFormat = "MMM d 'at' h:mma"
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
        return "\(stamp) (Asia/Taipei)"
    }
}
