import Foundation
import Testing
@testable import UsageMeterCore

@Suite("失敗重試退避")
struct BackoffTests {

    @Test("連續失敗指數遞增，但不超過上限")
    func exponentialUpToCap() {
        var backoff = RetryBackoff(policy: .claude)
        #expect(backoff.recordFailure() == 60)
        #expect(backoff.recordFailure() == 120)
        #expect(backoff.recordFailure() == 240)
        #expect(backoff.recordFailure() == 480)
        #expect(backoff.recordFailure() == 960)
        #expect(backoff.recordFailure() == 1800)
        #expect(backoff.recordFailure() == 1800)
        #expect(backoff.consecutiveFailures == 7)
    }

    @Test("成功後歸零")
    func resetsAfterSuccess() {
        var backoff = RetryBackoff(policy: .claude)
        _ = backoff.recordFailure()
        _ = backoff.recordFailure()
        backoff.reset()
        #expect(backoff.consecutiveFailures == 0)
        #expect(backoff.recordFailure() == 60)
    }

}

@Suite("每個供應商各自的參數")
struct PerProviderPolicyTests {

    /// The presenter used to build every provider's backoff from `.claude`, via a
    /// ternary whose branches were both `.claude`. Codex would have silently inherited
    /// a ceiling chosen for a penalty window Codex does not have.
    @Test("兩個供應商拿到的不是同一組參數")
    func providersDoNotShareConstants() {
        #expect(BackoffPolicy.forProvider(.claude) != BackoffPolicy.forProvider(.codex))
    }

    @Test("每個供應商都必須有明確的參數，沒有預設值可以矇混")
    func everyProviderIsAccountedFor() {
        for provider in ProviderKind.allCases {
            #expect(BackoffPolicy.forProvider(provider).cap > 0)
        }
    }
}
