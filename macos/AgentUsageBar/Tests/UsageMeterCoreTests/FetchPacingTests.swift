import Foundation
import Testing
@testable import UsageMeterCore

@Suite("查詢節流")
struct FetchPacingTests {

    let now = Date(timeIntervalSince1970: 1_000_000)
    let interval: TimeInterval = 1800

    /// The case that motivated this: nothing survived a quit, so every launch fired a
    /// request. Ten quick relaunches meant ten requests against an endpoint whose
    /// answer to too many is a twenty-minute block.
    @Test("連續重開不會連續送出請求")
    func relaunchDoesNotRefetch() {
        let decision = FetchPacing.decide(
            lastAttemptAt: nil,                       // fresh process, no memory of asking
            storedFetchedAt: now.addingTimeInterval(-60),
            interval: interval,
            reason: .scheduled,
            now: now
        )
        guard case .useStored(let freshFor) = decision else {
            Issue.record("一分鐘前的讀數應該繼續用，實得 \(decision)")
            return
        }
        // The remainder, not a full interval — otherwise relaunching would postpone
        // every refresh for as long as someone kept relaunching.
        #expect(freshFor == interval - 60)
    }

    @Test("讀數過期就重新查詢")
    func staleStoredTriggersFetch() {
        let decision = FetchPacing.decide(
            lastAttemptAt: nil,
            storedFetchedAt: now.addingTimeInterval(-interval - 1),
            interval: interval,
            reason: .scheduled,
            now: now
        )
        #expect(decision == .fetch)
    }

    @Test("沒有任何舊讀數時會查詢")
    func noStoredMeansFetch() {
        #expect(FetchPacing.decide(lastAttemptAt: nil, storedFetchedAt: nil,
                                   interval: interval, reason: .scheduled, now: now) == .fetch)
    }

    @Test("底線擋住任何來源的連續請求，包含手動")
    func floorAppliesToEveryTrigger() {
        for reason in [FetchPacing.Reason.manual, .scheduled] {
            let decision = FetchPacing.decide(
                lastAttemptAt: now.addingTimeInterval(-5),
                storedFetchedAt: nil,
                interval: interval,
                reason: reason,
                now: now
            )
            guard case .tooSoon(let retryAfter) = decision else {
                Issue.record("5 秒前才查過，reason=\(reason) 仍應被擋，實得 \(decision)")
                return
            }
            #expect(retryAfter == FetchPacing.floor - 5)
        }
    }

    /// A person clicking refresh has a reason — usually that the number matters right
    /// now. Refusing because a timer has not elapsed would make the button a lie.
    @Test("手動重新整理不受輪詢間隔限制")
    func manualIgnoresTheInterval() {
        let decision = FetchPacing.decide(
            lastAttemptAt: now.addingTimeInterval(-FetchPacing.floor - 1),
            storedFetchedAt: now.addingTimeInterval(-60),
            interval: interval,
            reason: .manual,
            now: now
        )
        #expect(decision == .fetch)
    }

    @Test("底線之外的自動查詢仍受間隔約束")
    func automaticStillRespectsTheInterval() {
        let decision = FetchPacing.decide(
            lastAttemptAt: now.addingTimeInterval(-FetchPacing.floor - 1),
            storedFetchedAt: now.addingTimeInterval(-60),
            interval: interval,
            reason: .scheduled,
            now: now
        )
        guard case .useStored = decision else {
            Issue.record("預期 useStored，實得 \(decision)")
            return
        }
    }

    @Test("未來的上次查詢時間不會阻止修復查詢")
    func futureAttemptDoesNotCreateAnUnboundedDelay() {
        let decision = FetchPacing.decide(
            lastAttemptAt: now.addingTimeInterval(86_400),
            storedFetchedAt: nil,
            interval: interval,
            reason: .scheduled,
            now: now
        )
        #expect(decision == .fetch)
    }

    @Test("未來的保存讀數不會被當成新鮮資料")
    func futureStoredReadingDoesNotCreateAnUnboundedDelay() {
        let decision = FetchPacing.decide(
            lastAttemptAt: nil,
            storedFetchedAt: now.addingTimeInterval(86_400),
            interval: interval,
            reason: .scheduled,
            now: now
        )
        #expect(decision == .fetch)
    }
}

@Suite("讀數的跨啟動保存")
struct UsageSnapshotStoreTests {

    private let storageVersion = "v1"

    func makeStore() -> (UsageSnapshotStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "aub.tests.\(UUID().uuidString)")!
        return (UsageSnapshotStore(defaults: suite), suite)
    }

    func snapshot(
        sourcePath: UsageSourcePath = .usageEndpoint,
        fetchedAt: Date = Date().addingTimeInterval(-60),
        resetAt: Date = Date().addingTimeInterval(3_600)
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            sourcePath: sourcePath,
            windows: [
                UsageWindow(
                    kind: .weeklyScoped, group: .weekly,
                    used: UsedPercent(hundredScale: 58),
                    resetsAt: resetAt,
                    isActive: true, modelDisplayName: "Opus 5"
                ),
                UsageWindow(
                    kind: .unrecognized("monthly_all"), group: .unrecognized("monthly"),
                    used: UsedPercent(unitScale: 0.29),
                    resetsAt: nil, isActive: false
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    func claudeCLISnapshot(
        sessionUsed: Double,
        sessionResetAt: Date?,
        weeklyResetAt: Date?
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            sourcePath: .claudeCodeCLI,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: sessionUsed),
                    resetsAt: sessionResetAt,
                    isActive: true
                ),
                UsageWindow(
                    kind: .weeklyAll,
                    group: .weekly,
                    used: UsedPercent(hundredScale: 42),
                    resetsAt: weeklyResetAt,
                    isActive: false
                ),
            ],
            fetchedAt: Date().addingTimeInterval(-60)
        )
    }

    func codexSnapshot(
        resetAt: Date?,
        accountUsage: CodexAccountUsage? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: 18),
                    resetsAt: resetAt,
                    isActive: true,
                    durationMinutes: 300
                ),
            ],
            fetchedAt: Date().addingTimeInterval(-60),
            codexAccountUsage: accountUsage
        )
    }

    func decodeClaudeCLISnapshot(session: String) throws -> UsageSnapshot {
        let result = """
        You are currently using your subscription to power your Claude Code usage

        Current session: \(session)
        Current week (all models): 7% used · resets Aug 31 at 12pm (Asia/Taipei)
        """
        let envelope: [String: Any] = [
            "is_error": false,
            "subtype": "success",
            "result": result,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try ClaudeUsageTextDecoder.decode(
            data,
            now: Date(timeIntervalSince1970: 1_787_576_400),
            timeZone: TimeZone(identifier: "Asia/Taipei")!
        )
    }

    func storedData(for provider: ProviderKind, defaults: UserDefaults) -> Data? {
        defaults.data(forKey: "\(storageVersion).snapshot.\(provider.rawValue)")
    }

    private func writeRaw(
        _ snapshot: UsageSnapshot,
        under provider: ProviderKind,
        defaults: UserDefaults,
        mutate: (inout [String: Any]) throws -> Void = { _ in }
    ) throws {
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        defaults.set(data, forKey: "\(storageVersion).snapshot.\(provider.rawValue)")
    }

    @Test("存進去再讀出來完全一致，未知的 kind 也是")
    func roundTrips() throws {
        let (store, _) = makeStore()
        let original = snapshot()
        store.save(original)
        let restored = try #require(store.load(.claude))
        #expect(restored == original)
        #expect(restored.windows[1].kind == .unrecognized("monthly_all"))
        #expect(restored.windows[1].used.originalScale == .unit)
    }

    /// Demo data coming back after a relaunch, presented as a reading, would be the
    /// "invented numbers shown as real" failure in its most convincing form.
    @Test("fixture 不會被保存")
    func fixturesAreNotPersisted() {
        let (store, _) = makeStore()
        store.save(snapshot(sourcePath: .fixture))
        #expect(store.load(.claude) == nil)
    }

    @Test("沒有存過就回 nil")
    func emptyStoreReturnsNil() {
        let (store, _) = makeStore()
        #expect(store.load(.claude) == nil)
        #expect(store.load(.codex) == nil)
    }

    @Test("兩個供應商各自獨立")
    func providersDoNotCollide() throws {
        let (store, _) = makeStore()
        store.save(snapshot())
        #expect(store.load(.codex) == nil)
        #expect(store.load(.claude) != nil)
    }

    @Test("Codex 帳號 Token 統計可隨最新 snapshot 往返")
    func codexAccountUsageRoundTrips() throws {
        let (store, _) = makeStore()
        let original = codexSnapshot(
            resetAt: nil,
            accountUsage: CodexAccountUsage(
                lifetimeTokens: 6_012_800_208,
                peakDailyTokens: 412_649_517,
                dailyUsageBuckets: [
                    .init(startDate: "2026-08-30", tokens: 100),
                    .init(startDate: "2026-08-31", tokens: 200),
                ]
            )
        )

        store.save(original)

        #expect(store.load(.codex) == original)
    }

    @Test("磁碟注入的無效 Token 日期不能進入畫面")
    func rejectsInvalidPersistedTokenDate() throws {
        let (store, defaults) = makeStore()
        let original = codexSnapshot(
            resetAt: nil,
            accountUsage: CodexAccountUsage(
                lifetimeTokens: 100,
                peakDailyTokens: 50,
                dailyUsageBuckets: [.init(startDate: "2026-08-31", tokens: 50)]
            )
        )
        try writeRaw(original, under: .codex, defaults: defaults) { object in
            var usage = try #require(object["codexAccountUsage"] as? [String: Any])
            var buckets = try #require(usage["dailyUsageBuckets"] as? [[String: Any]])
            buckets[0]["startDate"] = "2026-02-30"
            usage["dailyUsageBuckets"] = buckets
            object["codexAccountUsage"] = usage
        }

        #expect(store.load(.codex) == nil)
    }

    @Test("磁碟上的範圍外百分比不會被當成可信的 100%")
    func rejectsOutOfRangePersistedPercentage() throws {
        let (store, defaults) = makeStore()
        try writeRaw(snapshot(), under: .claude, defaults: defaults) { object in
            var windows = try #require(object["windows"] as? [[String: Any]])
            var used = try #require(windows.first?["used"] as? [String: Any])
            used["normalized"] = 250
            windows[0]["used"] = used
            object["windows"] = windows
        }

        #expect(store.load(.claude) == nil)
    }

    @Test("保存位置與 snapshot 的供應商不一致時拒絕讀取")
    func rejectsProviderMismatch() throws {
        let (store, defaults) = makeStore()
        try writeRaw(snapshot(), under: .codex, defaults: defaults)

        #expect(store.load(.codex) == nil)
    }

    @Test("手動塞入的 fixture 不會在重開後冒充真實讀數")
    func rejectsInjectedFixture() throws {
        let (store, defaults) = makeStore()
        try writeRaw(snapshot(sourcePath: .fixture), under: .claude, defaults: defaults)

        #expect(store.load(.claude) == nil)
    }

    @Test("供應商與資料來源不相容時拒絕讀取")
    func rejectsIncompatibleSourcePath() throws {
        let (store, defaults) = makeStore()
        try writeRaw(snapshot(sourcePath: .codexAppServer), under: .claude, defaults: defaults)

        #expect(store.load(.claude) == nil)
    }

    @Test("沒有任何時間窗的保存讀數不能阻止重新查詢")
    func rejectsSnapshotWithoutWindows() throws {
        let (store, defaults) = makeStore()
        try writeRaw(snapshot(), under: .claude, defaults: defaults) { object in
            object["windows"] = []
        }

        #expect(store.load(.claude) == nil)
    }

    @Test("Claude 尚未開始的新 session 可以沒有 reset")
    func acceptsZeroClaudeSessionWithoutReset() throws {
        let (store, _) = makeStore()
        let original = claudeCLISnapshot(
            sessionUsed: 0,
            sessionResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(3_600)
        )

        store.save(original)

        #expect(store.load(.claude) == original)
    }

    @Test("Claude decoder 接受的兩種 session 形狀都能保存")
    func acceptedClaudeDecoderShapesPassThePersistenceContract() throws {
        let decoded = try [
            decodeClaudeCLISnapshot(
                session: "42% used · resets Aug 25 at 1am (Asia/Taipei)"
            ),
            decodeClaudeCLISnapshot(session: "0% used"),
        ]

        for snapshot in decoded {
            let (store, _) = makeStore()
            store.save(snapshot)
            #expect(store.load(.claude, now: snapshot.fetchedAt) == snapshot)
        }
    }

    @Test("Claude CLI 快照容許額外的未知 window kind")
    func acceptsAnAdditionalUnknownClaudeWindow() throws {
        let base = claudeCLISnapshot(
            sessionUsed: 0,
            sessionResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(3_600)
        )
        let extra = UsageWindow(
            kind: .unrecognized("monthly_all"),
            group: .unrecognized("monthly"),
            used: UsedPercent(hundredScale: 29),
            resetsAt: nil,
            isActive: false
        )
        let original = UsageSnapshot(
            provider: .claude,
            sourcePath: .claudeCodeCLI,
            windows: base.windows + [extra],
            fetchedAt: base.fetchedAt
        )
        let (store, _) = makeStore()

        store.save(original)

        let restored = try #require(store.load(.claude))
        #expect(restored == original)
        #expect(restored.windows.last?.kind == .unrecognized("monthly_all"))
    }

    @Test("Claude 非零 session 缺少 reset 時不保存也不載入")
    func rejectsNonzeroClaudeSessionWithoutReset() throws {
        let invalid = claudeCLISnapshot(
            sessionUsed: 12,
            sessionResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(3_600)
        )

        let (saveStore, saveDefaults) = makeStore()
        saveStore.save(invalid)
        #expect(storedData(for: .claude, defaults: saveDefaults) == nil)
        #expect(saveStore.load(.claude) == nil)

        let (loadStore, defaults) = makeStore()
        try writeRaw(invalid, under: .claude, defaults: defaults)
        #expect(loadStore.load(.claude) == nil)
    }

    @Test("Claude weekly 缺少 reset 時不保存也不載入")
    func rejectsClaudeWeeklyWindowWithoutReset() throws {
        let invalid = claudeCLISnapshot(
            sessionUsed: 0,
            sessionResetAt: nil,
            weeklyResetAt: nil
        )

        let (saveStore, saveDefaults) = makeStore()
        saveStore.save(invalid)
        #expect(storedData(for: .claude, defaults: saveDefaults) == nil)
        #expect(saveStore.load(.claude) == nil)

        let (loadStore, defaults) = makeStore()
        try writeRaw(invalid, under: .claude, defaults: defaults)
        #expect(loadStore.load(.claude) == nil)
    }

    @Test("Codex 合法的 nil reset 保存規則維持不變")
    func acceptsCodexWindowWithoutReset() throws {
        let (store, _) = makeStore()
        let original = codexSnapshot(resetAt: nil)

        store.save(original)

        #expect(store.load(.codex) == original)
    }

    @Test("已跨過 reset 的保存讀數不會在重開後標成最新")
    func rejectsPersistedSnapshotPastItsReset() {
        let (store, _) = makeStore()
        let now = Date()
        store.save(snapshot(
            fetchedAt: now.addingTimeInterval(-60),
            resetAt: now.addingTimeInterval(-ClaudeUsageTextDecoder.resetGrace - 1)
        ))

        #expect(store.load(.claude, now: now) == nil)
    }

    @Test("未來時間的保存讀數不會在重開後標成最新")
    func rejectsPersistedSnapshotFromTheFuture() {
        let (store, _) = makeStore()
        let now = Date()
        store.save(snapshot(
            fetchedAt: now.addingTimeInterval(3_600),
            resetAt: now.addingTimeInterval(7_200)
        ))

        #expect(store.load(.claude, now: now) == nil)
    }

    @Test("過長的供應商欄位不會被保存，也不能由 defaults 注入")
    func rejectsOversizedPersistedMetadata() throws {
        let oversized = String(repeating: "x", count: 513)
        let invalid = UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: codexSnapshot(resetAt: nil).windows,
            fetchedAt: Date().addingTimeInterval(-60),
            planType: oversized
        )

        let (saveStore, saveDefaults) = makeStore()
        saveStore.save(invalid)
        #expect(storedData(for: .codex, defaults: saveDefaults) == nil)

        let (loadStore, loadDefaults) = makeStore()
        try writeRaw(invalid, under: .codex, defaults: loadDefaults)
        #expect(loadStore.load(.codex) == nil)
    }

    @Test("異常大的保存資料在 JSON 解碼前就拒絕")
    func rejectsOversizedPersistedPayload() {
        let (store, defaults) = makeStore()
        defaults.set(
            Data(repeating: 0x41, count: 65_537),
            forKey: "\(storageVersion).snapshot.codex"
        )

        #expect(store.load(.codex) == nil)
    }
}
