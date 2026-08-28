import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Codex 局部推播合併政策")
struct CodexRateLimitUpdatePolicyTests {
    private let baseFetchedAt = Date(timeIntervalSince1970: 1_000_000)
    private let pushFetchedAt = Date(timeIntervalSince1970: 2_000_000)

    private func window(
        kind: UsageWindow.Kind,
        used: Double,
        model: String? = nil
    ) -> UsageWindow {
        UsageWindow(
            kind: kind,
            group: kind == .session ? .session : .weekly,
            used: UsedPercent(hundredScale: used),
            resetsAt: Date(timeIntervalSince1970: 3_000_000 + used),
            isActive: kind == .session,
            modelDisplayName: model,
            durationMinutes: kind == .session ? 300 : 10_080
        )
    }

    private func baseSnapshot(
        provider: ProviderKind = .codex,
        sourcePath: UsageSourcePath = .codexAppServer,
        meteredLimitID: String? = "codex"
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            sourcePath: sourcePath,
            windows: [
                window(kind: .session, used: 10),
                window(kind: .weeklyAll, used: 60),
            ],
            fetchedAt: baseFetchedAt,
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "12.50"),
            planType: "plus",
            rateLimitReachedType: nil,
            spendControlReached: false,
            meteredLimitID: meteredLimitID,
            sourceVersion: "codex-cli/0.1"
        )
    }

    private func sparseUpdate(
        provider: ProviderKind = .codex,
        sourcePath: UsageSourcePath = .codexAppServer,
        meteredLimitID: String? = "codex",
        windows: [UsageWindow]? = nil,
        credits: UsageCredits? = nil,
        planType: String? = nil,
        rateLimitReachedType: String? = nil,
        spendControlReached: Bool? = nil,
        sourceVersion: String? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            sourcePath: sourcePath,
            windows: windows ?? [window(kind: .session, used: 31)],
            fetchedAt: pushFetchedAt,
            credits: credits,
            planType: planType,
            rateLimitReachedType: rateLimitReachedType,
            spendControlReached: spendControlReached,
            meteredLimitID: meteredLimitID,
            sourceVersion: sourceVersion
        )
    }

    private func requireSnapshot(
        _ result: UsageDisplayState?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> UsageSnapshot {
        let state = try #require(result, sourceLocation: sourceLocation)
        return try #require(state.snapshot, sourceLocation: sourceLocation)
    }

    @Test("sparse primary 只更新對應窗，完整資料與時間保持不變")
    func sparsePrimaryPreservesCompleteSnapshot() throws {
        let base = baseSnapshot()
        let result = CodexRateLimitUpdatePolicy.applying(
            sparseUpdate(),
            to: .current(base)
        )
        let merged = try requireSnapshot(result)

        #expect(merged.windows.map(\.id) == ["session", "weekly_all"])
        #expect(merged.windows[0].used.usedPercent == 31)
        #expect(merged.windows[1] == base.windows[1])
        #expect(merged.fetchedAt == baseFetchedAt)
        #expect(merged.credits == base.credits)
        #expect(merged.planType == "plus")
        #expect(merged.sourceVersion == "codex-cli/0.1")
    }

    @Test("推播真正提供的 metadata 會更新，新 window 依穩定 ID 附加")
    func providedMetadataAndNewWindowUpdate() throws {
        let scoped = window(kind: .weeklyScoped, used: 22, model: "Model A")
        let update = sparseUpdate(
            windows: [window(kind: .session, used: 31), scoped],
            credits: UsageCredits(hasCredits: true, unlimited: true, balance: nil),
            planType: "pro",
            rateLimitReachedType: "primary",
            spendControlReached: true,
            sourceVersion: "codex-cli/0.2"
        )
        let merged = try requireSnapshot(
            CodexRateLimitUpdatePolicy.applying(update, to: .current(baseSnapshot()))
        )

        #expect(merged.windows.map(\.id) == ["session", "weekly_all", "weekly_scoped#Model A"])
        #expect(merged.credits?.unlimited == true)
        #expect(merged.planType == "pro")
        #expect(merged.rateLimitReachedType == "primary")
        #expect(merged.spendControlReached == true)
        #expect(merged.sourceVersion == "codex-cli/0.2")
    }

    @Test("合併保留 current、stale、refreshing 與 throttled 的狀態語意")
    func preservesDisplayStateCase() throws {
        let base = baseSnapshot()
        let update = sparseUpdate()
        let staleReason = UsageError.offline
        let until = Date(timeIntervalSince1970: 4_000_000)

        guard case .current(let current)? = CodexRateLimitUpdatePolicy.applying(update, to: .current(base)) else {
            Issue.record("current 不得改變狀態類型")
            return
        }
        #expect(current.windows[0].used.usedPercent == 31)

        guard case .stale(let stale, let reason)? = CodexRateLimitUpdatePolicy.applying(
            update,
            to: .stale(base, reason: staleReason)
        ) else {
            Issue.record("stale 不得升級成 current")
            return
        }
        #expect(stale.windows[0].used.usedPercent == 31)
        #expect(reason == staleReason)

        guard case .refreshing(let refreshing)? = CodexRateLimitUpdatePolicy.applying(
            update,
            to: .refreshing(previous: base)
        ) else {
            Issue.record("refreshing 不得改變狀態類型")
            return
        }
        #expect(refreshing?.windows[0].used.usedPercent == 31)

        guard case .throttled(let throttled, let preservedUntil)? = CodexRateLimitUpdatePolicy.applying(
            update,
            to: .throttled(previous: base, until: until)
        ) else {
            Issue.record("throttled 不得升級成 current")
            return
        }
        #expect(throttled?.windows[0].used.usedPercent == 31)
        #expect(preservedUntil == until)
    }

    @Test("沒有可信完整 snapshot 時不套用局部推播")
    func rejectsStatesWithoutBaseSnapshot() {
        let update = sparseUpdate()
        #expect(CodexRateLimitUpdatePolicy.applying(update, to: .starting) == nil)
        #expect(CodexRateLimitUpdatePolicy.applying(update, to: .unavailable(.offline)) == nil)
        #expect(CodexRateLimitUpdatePolicy.applying(update, to: .refreshing(previous: nil)) == nil)
        #expect(
            CodexRateLimitUpdatePolicy.applying(
                update,
                to: .throttled(previous: nil, until: Date(timeIntervalSince1970: 4_000_000))
            ) == nil
        )
    }

    @Test("provider、來源或一般 bucket identity 不相容時拒絕合併")
    func rejectsIncompatibleSnapshots() {
        let base = baseSnapshot()
        #expect(
            CodexRateLimitUpdatePolicy.applying(
                sparseUpdate(provider: .claude),
                to: .current(base)
            ) == nil
        )
        #expect(
            CodexRateLimitUpdatePolicy.applying(
                sparseUpdate(sourcePath: .fixture),
                to: .current(base)
            ) == nil
        )
        #expect(
            CodexRateLimitUpdatePolicy.applying(
                sparseUpdate(meteredLimitID: "codex_other"),
                to: .current(base)
            ) == nil
        )
        #expect(
            CodexRateLimitUpdatePolicy.applying(
                sparseUpdate(),
                to: .current(baseSnapshot(meteredLimitID: "codex_other"))
            ) == nil
        )
    }

    @Test("舊版 nil bucket identity 與一般 codex bucket 相容")
    func acceptsLegacyMissingBucketIdentity() throws {
        let merged = try requireSnapshot(
            CodexRateLimitUpdatePolicy.applying(
                sparseUpdate(),
                to: .current(baseSnapshot(meteredLimitID: nil))
            )
        )
        #expect(merged.meteredLimitID == "codex")
    }
}
