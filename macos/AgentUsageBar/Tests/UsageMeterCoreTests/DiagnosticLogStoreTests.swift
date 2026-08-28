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
            let persisted = defaults.data(forKey: "v1.diagnosticLog")
            let text = persisted.flatMap { String(data: $0, encoding: .utf8) }
            #expect(text?.contains(marker) == false)
            #expect(text?.contains("/Users/private") == false)
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
