import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Codex Token 統計獨立合併政策")
struct CodexAccountUsageUpdatePolicyTests {
    let quotaFetchedAt = Date(timeIntervalSinceReferenceDate: 100)
    let tokenFetchedAt = Date(timeIntervalSinceReferenceDate: 200)

    func snapshot(token: Int = 10) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: [UsageWindow(
                kind: .session,
                group: .session,
                used: UsedPercent(hundredScale: 25),
                resetsAt: nil,
                isActive: true
            )],
            fetchedAt: quotaFetchedAt,
            codexAccountUsage: CodexAccountUsage(
                lifetimeTokens: token,
                peakDailyTokens: nil,
                dailyUsageBuckets: [],
                fetchedAt: quotaFetchedAt
            )
        )
    }

    var update: CodexAccountUsage {
        CodexAccountUsage(
            lifetimeTokens: 20,
            peakDailyTokens: 8,
            dailyUsageBuckets: [.init(startDate: "2026-09-01", tokens: 8)],
            fetchedAt: tokenFetchedAt
        )
    }

    @Test("只替換 Token 統計，不冒充額度更新")
    func preservesQuotaTruth() throws {
        let merged = try #require(
            CodexAccountUsageUpdatePolicy.applying(update, to: .current(snapshot()))?.snapshot
        )

        #expect(merged.fetchedAt == quotaFetchedAt)
        #expect(merged.representativeWindow?.used.usedPercent == 25)
        #expect(merged.codexAccountUsage == update)
    }

    @Test("refreshing 與 stale 的狀態語意保持不變")
    func preservesPresentationState() throws {
        let staleReason = UsageError.transport("old quota")
        let stale = try #require(
            CodexAccountUsageUpdatePolicy.applying(
                update,
                to: .stale(snapshot(), reason: staleReason)
            )
        )
        guard case .stale(let staleSnapshot, let reason) = stale else {
            Issue.record("Expected stale state")
            return
        }
        #expect(reason == staleReason)
        #expect(staleSnapshot.codexAccountUsage == update)

        let refreshing = try #require(
            CodexAccountUsageUpdatePolicy.applying(
                update,
                to: .refreshing(previous: snapshot())
            )
        )
        guard case .refreshing(let previous) = refreshing else {
            Issue.record("Expected refreshing state")
            return
        }
        #expect(previous?.codexAccountUsage == update)
    }

    @Test("沒有額度快照時不單獨建立假的完整狀態")
    func requiresQuotaSnapshot() {
        #expect(CodexAccountUsageUpdatePolicy.applying(update, to: .starting) == nil)
        #expect(CodexAccountUsageUpdatePolicy.applying(
            update,
            to: .unavailable(.transport("no quota"))
        ) == nil)
    }
}
