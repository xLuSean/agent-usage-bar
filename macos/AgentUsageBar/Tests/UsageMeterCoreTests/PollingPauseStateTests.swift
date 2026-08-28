import Testing
@testable import UsageMeterCore

@Suite("輪詢暫停原因")
struct PollingPauseStateTests {

    @Test("只有最後一個暫停原因解除時才恢復")
    func resumesOnlyAfterEveryReasonClears() {
        var state = PollingPauseState()

        #expect(state.isPaused == false)
        #expect(state.set(true, for: .systemSleep) == true)
        #expect(state.set(true, for: .displaySleep) == false)
        #expect(state.set(true, for: .screenLock) == false)
        #expect(state.isPaused == true)

        #expect(state.set(false, for: .displaySleep) == false)
        #expect(state.set(false, for: .systemSleep) == false)
        #expect(state.isPaused == true)
        #expect(state.set(false, for: .screenLock) == true)
        #expect(state.isPaused == false)
    }

    @Test("重複通知與未曾啟用的解除通知不會改變狀態")
    func duplicateNotificationsAreIdempotent() {
        var state = PollingPauseState()

        #expect(state.set(false, for: .screenLock) == false)
        #expect(state.set(true, for: .screenLock) == true)
        #expect(state.set(true, for: .screenLock) == false)
        #expect(state.set(false, for: .screenLock) == true)
        #expect(state.set(false, for: .screenLock) == false)
    }
}
