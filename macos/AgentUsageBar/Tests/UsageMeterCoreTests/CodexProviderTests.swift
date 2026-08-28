import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Codex provider 與 executable 定位")
struct CodexProviderTests {
    private actor FakeReader: CodexAppServerReading {
        let response: CodexAppServerRead
        private(set) var receivedPath: String?

        init(response: CodexAppServerRead) { self.response = response }

        func readRateLimits(configuredExecutablePath: String?) async throws -> CodexAppServerRead {
            receivedPath = configuredExecutablePath
            return response
        }

        func path() -> String? { receivedPath }
    }

    @Test("provider 只透過 client 取資料")
    func providerBoundary() async throws {
        let payload = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":44,"windowDurationMins":300,"resetsAt":1730947200}}}"#.utf8)
        let fake = FakeReader(response: CodexAppServerRead(
            payload: payload,
            serverUserAgent: "codex-cli/test"
        ))
        let provider = CodexUsageProvider(
            configuredExecutablePath: "/test/codex",
            client: fake
        )

        let snapshot = try await provider.fetch()
        #expect(snapshot.representativeWindow?.used.usedPercent == 44)
        #expect(snapshot.sourceVersion == "codex-cli/test")
        #expect(await fake.path() == "/test/codex")
    }

    @Test("明確路徑必須是可執行的一般檔案")
    func explicitPathValidation() throws {
        let executable = try CodexExecutableLocator(
            configuredPath: "/bin/echo",
            environment: [:]
        ).locate()
        #expect(executable.lastPathComponent == "echo")

        do {
            _ = try CodexExecutableLocator(
                configuredPath: "/etc/hosts",
                environment: [:]
            ).locate()
            Issue.record("不可執行的檔案不應通過")
        } catch let error as UsageError {
            #expect(error == .codexExecutableInvalid("/etc/hosts"))
        }
    }

    @Test("自動定位會讀 CODEX_EXECUTABLE，找不到時回專用錯誤")
    func automaticLocation() throws {
        let located = try CodexExecutableLocator(
            environment: ["CODEX_EXECUTABLE": "/bin/echo", "PATH": ""]
        ).locate()
        #expect(located.lastPathComponent == "echo")

        do {
            _ = try CodexExecutableLocator(
                environment: ["PATH": "/definitely/not/a/real/path"],
                commonCandidatePaths: []
            ).locate()
            Issue.record("沒有任何可用候選時不應成功")
        } catch let error as UsageError {
            #expect(error == .codexExecutableNotFound)
        }
    }

    @Test("新增 Codex 欄位後仍能讀取舊版保存的 snapshot")
    func legacySnapshotCompatibility() throws {
        let snapshot = UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: [UsageWindow(
                kind: .session,
                group: .session,
                used: UsedPercent(hundredScale: 21),
                resetsAt: nil,
                isActive: true,
                durationMinutes: 300
            )],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 123),
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "10"),
            planType: "plus",
            rateLimitReachedType: "primary",
            spendControlReached: false,
            meteredLimitID: "codex",
            sourceVersion: "codex-cli/test"
        )

        let encoded = try JSONEncoder().encode(snapshot)
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "credits", "planType", "rateLimitReachedType", "spendControlReached",
            "meteredLimitID", "sourceVersion",
        ] {
            legacyObject.removeValue(forKey: key)
        }
        var windows = try #require(legacyObject["windows"] as? [[String: Any]])
        windows[0].removeValue(forKey: "durationMinutes")
        // Older versions persisted these retired fields. Synthesized Codable must
        // ignore them so an upgrade can still restore the snapshot.
        legacyObject["extraUsageEnabled"] = false
        legacyObject["observedTopLevelKeys"] = ["rateLimits", "futureField"]
        legacyObject["rateLimitHeaders"] = ["retry-after": "60"]
        windows[0]["severity"] = "warning"
        legacyObject["windows"] = windows

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: legacyData)

        #expect(decoded.representativeWindow?.used.usedPercent == 21)
        #expect(decoded.representativeWindow?.durationMinutes == nil)
        #expect(decoded.credits == nil)
        #expect(decoded.planType == nil)
        #expect(decoded.sourceVersion == nil)

        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(reencoded["extraUsageEnabled"] == nil)
    }
}
