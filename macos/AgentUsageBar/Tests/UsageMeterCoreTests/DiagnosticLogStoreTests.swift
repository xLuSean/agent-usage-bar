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
}
