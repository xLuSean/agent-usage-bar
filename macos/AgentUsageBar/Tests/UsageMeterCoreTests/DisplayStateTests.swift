import Foundation
import Testing
@testable import UsageMeterCore

@Suite("狀態模型")
struct DisplayStateTests {

    let snapshot = UsageSnapshot(
        provider: .claude,
        sourcePath: .usageEndpoint,
        windows: [
            UsageWindow(
                kind: .session, group: .session,
                used: UsedPercent(hundredScale: 29),
                resetsAt: Date(timeIntervalSince1970: 2_000_000),
                isActive: true
            )
        ],
        fetchedAt: Date(timeIntervalSince1970: 1_000_000)
    )

    @Test("有舊資料時失敗顯示 stale，並保留舊資料")
    func failureWithPreviousBecomesStale() {
        let state = UsageDisplayState.afterFailure(.offline, previous: snapshot)
        guard case .stale(let kept, let reason) = state else {
            Issue.record("預期 stale，實得 \(state)")
            return
        }
        #expect(kept == snapshot)
        #expect(reason == .offline)
        #expect(state.isDataTrustworthyAsCurrent == false)
    }

    @Test("沒有任何可信資料時顯示 unavailable，且不換算成 0%")
    func failureWithoutPreviousBecomesUnavailable() {
        let state = UsageDisplayState.afterFailure(.claudeNotSignedIn, previous: nil)
        guard case .unavailable = state else {
            Issue.record("預期 unavailable，實得 \(state)")
            return
        }
        // The critical part: no snapshot at all, rather than a snapshot reading 0%.
        #expect(state.snapshot == nil)
    }

    @Test("429 走 throttled，不併入 stale", arguments: [true, false])
    func rateLimitedBecomesThrottled(hasPrevious: Bool) {
        let until = Date(timeIntervalSince1970: 1_001_000)
        let state = UsageDisplayState.afterFailure(
            .rateLimited(retryAfter: until),
            previous: hasPrevious ? snapshot : nil
        )
        guard case .throttled(let previous, let recoversAt) = state else {
            Issue.record("預期 throttled，實得 \(state)")
            return
        }
        #expect(recoversAt == until)
        #expect((previous != nil) == hasPrevious)
    }

    @Test("429 沒帶 Retry-After 時，恢復時間退回退避上限而不是未知")
    func rateLimitedWithoutRetryAfterStillHasRecoveryTime() {
        let state = UsageDisplayState.afterFailure(.rateLimited(retryAfter: nil), previous: nil)
        guard case .throttled(_, let until) = state else {
            Issue.record("預期 throttled，實得 \(state)")
            return
        }
        #expect(until.timeIntervalSinceNow > BackoffPolicy.claude.cap - 2)
    }

    @Test("每種錯誤都對應到可解釋的狀態", arguments: [
        UsageError.claudeNotSignedIn,
        .claudeExecutableNotFound,
        .claudeExecutableInvalid("/bad/claude"),
        .claudeVersionUnsupported("x"),
        .claudeCommandFailed("x"),
        .claudeCommandTimedOut,
        .claudeUsageOutdated(resetsAt: Date(timeIntervalSince1970: 1_787_576_400)),
        .claudeUsageUnavailable,
        .offline,
        .schemaChanged("x"),
        .codexExecutableNotFound,
        .codexExecutableInvalid("/bad/codex"),
        .codexNotLoggedIn,
        .codexVersionIncompatible("x"),
        .codexRequestTimedOut("account/rateLimits/read"),
        .codexAppServerUnavailable("x"),
    ])
    func everyErrorHasAnExplanation(error: UsageError) {
        #expect(error.shortDescription.isEmpty == false)
        #expect(error.remedy?.isEmpty == false)
        let state = UsageDisplayState.afterFailure(error, previous: nil)
        #expect(state.error == error)
        #expect(state.statusLabel.isEmpty == false)
    }

    @Test("共用 schema 錯誤不把 Codex 問題誤說成 Claude /usage 問題")
    func schemaRemedyIsProviderNeutral() throws {
        let error = UsageError.schemaChanged("synthetic detail")
        let english = try #require(error.remedy(locale: Locale(identifier: "en_US")))
        let chinese = try #require(error.remedy(locale: Locale(identifier: "zh_Hant_TW")))

        #expect(english.contains("synthetic detail"))
        #expect(chinese.contains("synthetic detail"))
        #expect(english.localizedCaseInsensitiveContains("Claude") == false)
        #expect(english.contains("/usage") == false)
        #expect(chinese.localizedCaseInsensitiveContains("Claude") == false)
        #expect(chinese.contains("/usage") == false)
    }

    /// The two failures a user is most likely to confuse. One means Claude Code has no
    /// sign-in; the other means it answered from a cache whose window has ended. Only the
    /// first is fixed by running `claude`, so the messages must not converge.
    @Test("未登入與讀數過期是不同狀態，訊息不可混用")
    func signedOutIsNotAStaleReading() {
        let outdated = UsageError.claudeUsageOutdated(resetsAt: Date(timeIntervalSince1970: 1_787_576_400))
        #expect(UsageError.claudeNotSignedIn.shortDescription != outdated.shortDescription)
        #expect(ClaudeSignInRecovery.isAvailable(for: .claudeNotSignedIn))
        #expect(ClaudeSignInRecovery.isAvailable(for: outdated) == false)
    }

    /// Claude Code ran but had no figure from the server. The last good reading is kept
    /// and marked as old; it is never replaced by nothing, and running `claude` to sign
    /// in is not the step that fixes a failed lookup.
    @Test("Claude Code 沒取得最新額度時保留舊讀數並標示為過期")
    func aFailedLookupKeepsTheLastReadingAsStale() {
        let previous = UsageSnapshot(
            provider: .claude,
            sourcePath: .claudeCodeCLI,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: 44),
                    resetsAt: Date(timeIntervalSince1970: 1_787_590_800),
                    isActive: false
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_787_576_400)
        )

        let state = UsageDisplayState.afterFailure(.claudeUsageUnavailable, previous: previous)
        guard case .stale(let kept, let reason) = state else {
            Issue.record("預期 stale，實得 \(state)")
            return
        }
        #expect(kept == previous)
        #expect(reason == .claudeUsageUnavailable)
        #expect(state.isDataTrustworthyAsCurrent == false)

        guard case .unavailable = UsageDisplayState.afterFailure(.claudeUsageUnavailable, previous: nil) else {
            Issue.record("沒有舊讀數時應為 unavailable")
            return
        }
        #expect(ClaudeSignInRecovery.isAvailable(for: .claudeUsageUnavailable) == false)
        #expect(UsageError.claudeUsageUnavailable.isThrottling == false)
        #expect(UsageError.claudeUsageUnavailable.shortDescription
            != UsageError.claudeUsageOutdated(resetsAt: .distantPast).shortDescription)
    }

    /// A missing install and an install too old to answer need different steps, and
    /// neither is fixed by the command offered for being signed out.
    @Test("找不到執行檔與版本過舊是不同的訊息")
    func missingExecutableIsNotAnOldBuild() {
        #expect(
            UsageError.claudeExecutableNotFound.shortDescription
                != UsageError.claudeVersionUnsupported("x").shortDescription
        )
        #expect(UsageError.claudeExecutableNotFound.remedy?.isEmpty == false)
        #expect(UsageError.claudeVersionUnsupported("x").remedy?.isEmpty == false)
    }

    @Test("refreshing 保留前一份資料，starting 則沒有資料")
    func transientStates() {
        #expect(UsageDisplayState.refreshing(previous: snapshot).snapshot == snapshot)
        #expect(UsageDisplayState.refreshing(previous: snapshot).isDataTrustworthyAsCurrent)
        #expect(UsageDisplayState.refreshing(previous: nil).isDataTrustworthyAsCurrent == false)
        #expect(UsageDisplayState.starting.snapshot == nil)
    }
}

@Suite("尚未實作的 provider")
struct NotImplementedProviderTests {

    @Test("尚未實作是預期中的限制，不是故障")
    func isExpectedRatherThanFaulty() {
        let error = UsageError.notImplemented("Codex 端尚未實作")
        #expect(error.isExpectedLimitation)
        #expect(error.isThrottling == false)
        #expect(error.shortDescription == "Not implemented")
    }

    @Test("真正的故障不會被誤認為預期中的限制")
    func realFailuresAreNotExcused() {
        // Otherwise a network outage would stop retrying and sit there looking benign.
        for error in [UsageError.offline, .claudeCommandFailed("x"), .rateLimited(retryAfter: nil), .transport("x")] {
            #expect(error.isExpectedLimitation == false)
        }
    }

    @Test("沒有資料時仍走 unavailable，不會偽造讀數")
    func stillUnavailable() {
        let state = UsageDisplayState.afterFailure(.notImplemented("x"), previous: nil)
        guard case .unavailable = state else {
            Issue.record("預期 unavailable，實得 \(state)")
            return
        }
        #expect(state.snapshot == nil)
    }
}

@Suite("重設時間的呈現")
struct ResetDescriptionTests {

    let now = Date(timeIntervalSince1970: 1_755_500_000)

    /// Pinned because "same day" is a calendar question. `now` is seven minutes before
    /// midnight at UTC−7, so on a machine set to Pacific time a reset ten minutes out
    /// falls on the next day, gains a date of its own, and the comparison below fails
    /// for a reason that has nothing to do with the formatter.
    let timeZone = TimeZone.gmt

    @Test("當天重設只給時間")
    func sameDayOmitsDate() {
        let text = TimeFormatting.resetDescription(
            now.addingTimeInterval(3_600), now: now, timeZone: timeZone
        )
        #expect(text.contains("(in "))
    }

    /// Regression: a seven-day window showed only a clock time, which cannot be placed
    /// on a calendar — "11:59 AM" could be tomorrow or six days away.
    @Test("跨日重設必須帶日期")
    func laterDayCarriesDate() {
        let threeDaysOut = now.addingTimeInterval(3 * 86_400)
        let text = TimeFormatting.resetDescription(threeDaysOut, now: now, timeZone: timeZone)
        let sameDay = TimeFormatting.resetDescription(
            now.addingTimeInterval(600), now: now, timeZone: timeZone
        )
        // The cross-day form is strictly longer because it carries a date the other omits.
        #expect(text.count > sameDay.count)
        #expect(text.contains("(in "))
    }

    @Test("已過的重設時間不加相對描述")
    func pastResetHasNoCountdown() {
        let text = TimeFormatting.resetDescription(now.addingTimeInterval(-600), now: now)
        #expect(text.contains("(in ") == false)
    }

    @Test("重設時間可依 App 選擇呈現英文或繁體中文")
    func supportsBothDisplayLanguages() {
        let target = now.addingTimeInterval(3_600)
        let english = TimeFormatting.resetDescription(
            target, now: now, locale: Locale(identifier: "en_US")
        )
        let chinese = TimeFormatting.resetDescription(
            target, now: now, locale: Locale(identifier: "zh_Hant_TW")
        )
        #expect(english.contains("(in "))
        #expect(chinese.contains("後）"))
    }
}
