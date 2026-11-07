import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Privacy-safe diagnostic log")
struct DiagnosticLogStoreTests {
    private func withStore(_ body: (DiagnosticLogStore, UserDefaults) throws -> Void) rethrows {
        let suite = "io.github.sean.AgentUsageBar.tests.diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(DiagnosticLogStore(defaults: defaults), defaults)
    }

    @Test("default retention is five days and valid choices persist")
    func retentionPreference() {
        withStore { store, _ in
            #expect(store.loadRetention() == .fiveDays)
            _ = store.saveRetention(.threeDays)
            #expect(store.loadRetention() == .threeDays)
            _ = store.saveRetention(.sevenDays)
            #expect(store.loadRetention() == .sevenDays)
        }
    }

    @Test("associated provider text is discarded before persistence")
    func stripsUntrustedDetails() {
        withStore { store, defaults in
            let marker = "token-secret-marker-/Users/private"
            let entries = store.append(
                provider: .claude,
                error: .schemaChanged(marker),
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )

            #expect(entries.count == 1)
            #expect(entries[0].kind == .schemaChanged)
            #expect(entries[0].detail == .unrecognizedResponse)
            let persisted = defaults.data(forKey: "v1.diagnosticLog")
            let text = persisted.flatMap { String(data: $0, encoding: .utf8) }
            #expect(text?.contains(marker) == false)
            #expect(text?.contains("/Users/private") == false)
            #expect(entries[0].copyText(locale: Locale(identifier: "en_US")).contains(marker) == false)
        }
    }

    @Test("known Claude decoder failures retain a precise app-authored detail")
    func retainsSafeClaudeDetail() {
        withStore { store, defaults in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let entries = store.append(
                provider: .claude,
                error: .schemaChanged("Missing the \"Current week (all models)\" line"),
                now: now
            )

            #expect(entries.count == 1)
            #expect(entries[0].detail == .claudeWeeklyLineMissing)
            #expect(entries[0].detailMessage(locale: Locale(identifier: "en_US")) ==
                    "Claude Code did not return the Current week (all models) usage line.")
            #expect(entries[0].detailMessage(locale: Locale(identifier: "zh_Hant_TW")) ==
                    "Claude Code 沒有回傳 Current week (all models) 用量行。")
            let copied = entries[0].copyText(locale: Locale(identifier: "en_US"))
            #expect(copied.contains("Provider: Claude"))
            #expect(copied.contains("Error: Response format changed"))
            #expect(copied.contains("Detail: Claude Code did not return the Current week (all models) usage line."))

            let persisted = defaults.data(forKey: "v1.diagnosticLog")
            let persistedText = persisted.flatMap { String(data: $0, encoding: .utf8) }
            #expect(persistedText?.contains("Current week (all models)") == false)
            #expect(persistedText?.contains("claudeWeeklyLineMissing") == true)
        }
    }

    @Test("usage report failures retain a precise app-authored detail")
    func retainsSafeUsageReportDetail() {
        let expected: [(String, DiagnosticErrorDetail)] = [
            ("Command output has no result message", .claudeResultMessageMissing),
            ("Found 2 result messages", .claudeResultMessageDuplicated),
            ("Found 3 usage reports", .claudeUsageReportDuplicated),
            ("Unreadable usage report", .claudeUsageReportUnreadable),
            ("The usage report contains no limit rows", .claudeUsageReportEmpty),
            ("Found 2 \"session\" usage rows", .claudeUsageRowDuplicated),
            ("Unreadable percentage in the \"weekly_all\" usage row", .claudeUsageRowPercentageInvalid),
            ("Unreadable reset time in the \"session\" usage row", .claudeUsageRowResetInvalid),
            ("Missing reset time in the \"weekly_all\" usage row", .claudeUsageRowResetMissing),
        ]
        for (rawDetail, detail) in expected {
            #expect(DiagnosticErrorDetail(provider: .claude, error: .schemaChanged(rawDetail)) == detail)
            // Every closed detail explains itself in both languages, and none of them is
            // the "could not recognize" fallback.
            for identifier in ["en_US", "zh_Hant_TW"] {
                let message = detail.displayName(kind: .schemaChanged, locale: Locale(identifier: identifier))
                #expect(!message.isEmpty)
                #expect(message != DiagnosticErrorDetail.unrecognizedResponse
                    .displayName(kind: .schemaChanged, locale: Locale(identifier: identifier)))
            }
            // The same wording from Codex is not a known Codex failure.
            #expect(DiagnosticErrorDetail(provider: .codex, error: .schemaChanged(rawDetail)) == .unrecognizedResponse)
        }
    }

    @Test("a lookup that failed inside Claude Code is its own diagnostic kind")
    func recordsAFailedLookup() {
        withStore { store, _ in
            let entries = store.append(
                provider: .claude,
                error: .claudeUsageUnavailable,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            #expect(entries[0].kind == .claudeUsageUnavailable)
            #expect(entries[0].detail == .categorySummary)
            #expect(entries[0].detailMessage(locale: Locale(identifier: "en_US")) ==
                    "Claude Code returned a usage report without any usage figures from the server.")
            #expect(entries[0].detailMessage(locale: Locale(identifier: "zh_Hant_TW")) ==
                    "Claude Code 回傳了用量報告，但裡面沒有來自伺服器的額度資料。")
        }
    }

    @Test("a lost sign-in that still exits 0 is logged as a sign-in problem, not a format change")
    func recordsALostSignInFromTheCostSummary() throws {
        try withStore { store, defaults in
            let marker = "987.6543-secret-marker"
            let output = ClaudeUsageTextDecoderTests.envelope(
                ClaudeUsageTextDecoderTests.costSummary(cost: marker)
            )
            let error: UsageError
            do {
                _ = try ClaudeUsageDecoder.decode(output, now: Date(timeIntervalSince1970: 1_800_000_000))
                Issue.record("Expected claudeNotSignedIn")
                return
            } catch let decoded as UsageError {
                error = decoded
            }

            let entries = store.append(provider: .claude, error: error, now: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(entries[0].kind == .claudeNotSignedIn)
            #expect(entries[0].detail == .categorySummary)
            #expect(entries[0].detailMessage(locale: Locale(identifier: "en_US")) ==
                    "Claude Code reported that no usable sign-in state was available.")
            #expect(entries[0].copyText(locale: Locale(identifier: "en_US")).contains(marker) == false)
            let persisted = defaults.data(forKey: "v1.diagnosticLog")
            let persistedText = persisted.flatMap { String(data: $0, encoding: .utf8) }
            #expect(persistedText?.contains(marker) == false)
            #expect(persistedText?.contains("Total cost") == false)
        }
    }

    @Test("dynamic provider values are reduced to a fixed diagnostic detail")
    func stripsDynamicSchemaValues() {
        withStore { store, defaults in
            let marker = "999-secret-marker"
            let entries = store.append(
                provider: .claude,
                error: .schemaChanged("Percentage \(marker) is out of range in \"Current session\""),
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )

            #expect(entries[0].detail == .claudeSessionPercentageInvalid)
            #expect(entries[0].detailMessage(locale: Locale(identifier: "en_US")) ==
                    "Claude Code returned an invalid Current session percentage.")
            let persisted = defaults.data(forKey: "v1.diagnosticLog")
            let persistedText = persisted.flatMap { String(data: $0, encoding: .utf8) }
            #expect(persistedText?.contains(marker) == false)
        }
    }

    @Test("logs written before detailed diagnostics still decode")
    func decodesLegacyEntries() {
        struct LegacyEntry: Codable {
            let id: UUID
            let occurredAt: Date
            let provider: ProviderKind
            let kind: DiagnosticErrorKind
        }

        withStore { store, defaults in
            let legacy = LegacyEntry(
                id: UUID(),
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                provider: .claude,
                kind: .schemaChanged
            )
            defaults.set(try! JSONEncoder().encode([legacy]), forKey: "v1.diagnosticLog")

            let entries = store.load(now: Date(timeIntervalSince1970: 1_800_000_001))
            #expect(entries.count == 1)
            #expect(entries[0].detail == nil)
            #expect(entries[0].detailMessage(locale: Locale(identifier: "en_US")) ==
                    "This older log entry did not save additional diagnostic detail.")
        }
    }

    @Test("retention prunes old and future entries immediately")
    func prunesByRetentionAndRejectsFutureDates() {
        withStore { store, defaults in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = store.saveRetention(.sevenDays, now: now)
            _ = store.append(provider: .claude, error: .offline, now: now.addingTimeInterval(-6 * 86_400))
            _ = store.append(provider: .codex, error: .offline, now: now)

            let threeDays = store.saveRetention(.threeDays, now: now)
            #expect(threeDays.count == 1)
            #expect(threeDays[0].provider == .codex)

            let future = DiagnosticLogEntry(
                occurredAt: now.addingTimeInterval(1),
                provider: .claude,
                kind: .transport
            )
            let encoded = try! JSONEncoder().encode(threeDays + [future])
            defaults.set(encoded, forKey: "v1.diagnosticLog")
            #expect(store.load(now: now).count == 1)
        }
    }

    @Test("oversized persisted diagnostics are rejected before decoding")
    func rejectsOversizedPersistedData() {
        withStore { store, defaults in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let entry = DiagnosticLogEntry(
                occurredAt: now,
                provider: .claude,
                kind: .schemaChanged,
                detail: .claudeWeeklyLineMissing
            )
            let encoded = try! JSONEncoder().encode([entry])
            let maximumStoredBytes = DiagnosticLogStore.maximumStoredBytes
            #expect(encoded.count < maximumStoredBytes)

            var atLimit = encoded
            atLimit.append(
                Data(repeating: 0x20, count: maximumStoredBytes - encoded.count)
            )
            defaults.set(atLimit, forKey: "v1.diagnosticLog")
            #expect(store.load(now: now).count == 1)

            var oversized = atLimit
            oversized.append(0x20)
            defaults.set(oversized, forKey: "v1.diagnosticLog")
            #expect(store.load(now: now).isEmpty)
            #expect(defaults.object(forKey: "v1.diagnosticLog") == nil)
        }
    }

    @Test("entry count is bounded and clear leaves retention alone")
    func boundsAndClears() {
        withStore { store, _ in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = store.saveRetention(.sevenDays, now: now)
            for offset in 0...(DiagnosticLogStore.maximumEntries + 20) {
                _ = store.append(
                    provider: .codex,
                    error: .codexAppServerUnavailable("ignored-\(offset)"),
                    now: now.addingTimeInterval(TimeInterval(offset))
                )
            }
            #expect(store.load(now: now.addingTimeInterval(300)).count == DiagnosticLogStore.maximumEntries)
            store.clear()
            #expect(store.load(now: now.addingTimeInterval(300)).isEmpty)
            #expect(store.loadRetention() == .sevenDays)
        }
    }

    @Test("the next success annotates only the latest failure for that query, including across launches")
    func correlatesRecoveryPerQuery() {
        withStore { store, defaults in
            let now = Date()
            var quota = CodexQueryDiagnostic(method: .rateLimitsRead)
            quota.process = .init(startedAt: now.addingTimeInterval(-200), reused: true)
            var tokens = CodexQueryDiagnostic(method: .accountUsageRead)
            tokens.process = quota.process
            #expect(store.recordRecovery(for: tokens, now: now).isEmpty)
            let error = UsageError.codexAppServerUnavailable("private-marker")
            for (offset, query) in [quota, tokens, quota].enumerated() {
                _ = store.append(provider: .codex, error: error, codexQuery: query,
                                 now: now.addingTimeInterval(Double(offset)))
            }
            let reloaded = DiagnosticLogStore(defaults: defaults)
            quota.process = .init(startedAt: now.addingTimeInterval(3), reused: false)
            let later = now.addingTimeInterval(5)
            let entries = reloaded.recordRecovery(for: quota, now: later)
            let en = Locale(identifier: "en_US")
            #expect(entries.count == 3)
            #expect(entries[0].copyText(locale: en).contains("using a different background process"))
            #expect(!entries[1].copyText(locale: en).contains("Retry succeeded"))
            #expect(!entries[2].copyText(locale: en).contains("Retry succeeded"))
            #expect(reloaded.recordRecovery(for: quota, now: later.addingTimeInterval(1)) == entries)
            _ = reloaded.recordRecovery(for: tokens, now: later)
            #expect(store.load(now: later)[1].copyText(locale: en).contains("using the same background process"))
            store.clear()
            #expect(store.recordRecovery(for: quota, now: later).isEmpty)
            #expect(store.load(now: later).isEmpty)
        }
    }

    @Test("expiry explanations keep only explicitly reported service codes after storage and copying")
    func separatesReportedCodesFromProse() throws {
        let phrase = "Your authentication token has expired. Please try refreshing it."
        let old = try JSONDecoder().decode(CodexRPCRejection.self, from: Data(
            #"{"code":-32603,"httpStatus":401,"reason":"tokenExpired"}"#.utf8
        ))
        let cases: [(CodexRPCRejection, Bool)] = [
            (.init(code: -32603, message: phrase), false),
            (.init(code: -32603, message: "GET https://fixture.invalid failed: 401 Unauthorized; body={\"error\":{\"message\":\"\(phrase)\"}}"), false),
            (.init(code: -32603, message: phrase, data: ["code": "private-marker"]), false),
            (old, false),
            (.init(code: -32603, message: "internal error", data: ["error": ["code": "token_expired"]]), true),
            (.init(code: -32603, message: "token_expired"), true),
        ]
        try withStore { store, defaults in
            for (rejection, reported) in cases {
                var query = CodexQueryDiagnostic(method: .rateLimitsRead)
                query.rpc = rejection
                store.clear()
                _ = store.append(provider: .codex, error: rejection.usageError(for: .rateLimitsRead), codexQuery: query)
                let entry = try #require(store.load().first)
                let zh = Locale(identifier: "zh_Hant_TW")
                #expect(entry.detailMessage(locale: zh).contains("登入憑證已過期"))
                for locale in [zh, Locale(identifier: "en_US")] {
                    #expect(entry.detailMessage(locale: locale).contains("token_expired") == reported)
                    #expect(entry.copyText(locale: locale).contains("token_expired") == reported)
                    #expect(!entry.copyText(locale: locale).contains("private-marker"))
                }
                let bytes = try #require(defaults.data(forKey: "v1.diagnosticLog"))
                #expect(!String(decoding: bytes, as: UTF8.self).contains("private-marker"))
            }
        }
    }

    @Test("a successful query returns the retained history even when it has no recovery to annotate")
    func returnsPrunedHistoryWithoutRecovery() {
        withStore { store, _ in
            let before = Date()
            _ = store.append(provider: .claude, error: .offline, now: before)
            let later = before.addingTimeInterval(5 * 86_400 + 1)
            let recent = store.append(provider: .claude, error: .offline, now: later.addingTimeInterval(-2))
            #expect(recent.count == 2)
            let quota = CodexQueryDiagnostic(method: .rateLimitsRead)
            #expect(store.recordRecovery(for: quota, now: later) == Array(recent.prefix(1)))
            #expect(store.load(now: later) == Array(recent.prefix(1)))
        }
    }

    @Test("rich diagnostics keep their newest entries within the encoded byte limit")
    func boundsRichHistory() throws {
        try withStore { store, defaults in
            let now = Date()
            var query = CodexQueryDiagnostic(method: .rateLimitsRead)
            query.process = .init(startedAt: now, reused: false)
            query.failedDuringInitialization = true
            query.rpc = CodexRPCRejection(code: -32603, message: "HTTP 401 Unauthorized")
            let error = UsageError.codexAppServerUnavailable("private-marker")
            var latest: DiagnosticLogEntry?
            for offset in 0...DiagnosticLogStore.maximumEntries {
                let time = now.addingTimeInterval(Double(offset))
                latest = store.append(provider: .codex, error: error, codexQuery: query, now: time).first
                _ = store.recordRecovery(for: query, now: time)
            }
            let data = try #require(defaults.data(forKey: "v1.diagnosticLog"))
            let readback = store.load(now: now.addingTimeInterval(300))
            #expect(data.count <= DiagnosticLogStore.maximumStoredBytes)
            #expect(!readback.isEmpty && readback.count < DiagnosticLogStore.maximumEntries)
            #expect(readback.first?.id == latest?.id)
            #expect(!String(decoding: data, as: UTF8.self).contains("private-marker"))
        }
    }
}
