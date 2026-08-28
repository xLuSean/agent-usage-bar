import Darwin
import Foundation
import Testing
@testable import UsageMeterCore

/// Starts only the repository's neutral stub. It never launches `codex`, opens a
/// network connection, or reads account state.
@Suite("Codex App Server process lifecycle", .serialized)
struct CodexAppServerClientTests {
    private let stateEnvironmentKey = "AGENT_USAGE_BAR_CODEX_STUB_STATE"

    @Test("provider error text is classified without reaching user-visible detail")
    func providerErrorTextIsSanitized() {
        let privateUpstreamText = "request failed for /Users/private/account.json token=do-not-display"

        let generic = CodexAppServerClient.mapRPCError(code: -32000, message: privateUpstreamText)
        #expect(generic.remedy?.contains(privateUpstreamText) == false)
        #expect(generic.remedy?.contains("/Users/private") == false)

        let unsupported = CodexAppServerClient.mapRPCError(
            code: -32601,
            message: "method not found; \(privateUpstreamText)"
        )
        #expect(unsupported.remedy?.contains(privateUpstreamText) == false)
        #expect(unsupported.remedy?.contains("/Users/private") == false)
    }

    @Test("read timeout discards the hung process and the next read uses a new process")
    func timeoutReplacesTheConnection() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-timeout-stub")
        #expect(FileManager.default.isExecutableFile(atPath: fixtureURL.path))

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-codex-timeout-\(UUID().uuidString)")
        let pidLogURL = URL(fileURLWithPath: stateURL.path + ".pids")
        let cwdLogURL = URL(fileURLWithPath: stateURL.path + ".cwd")
        let pwdLogURL = URL(fileURLWithPath: stateURL.path + ".pwd")
        #expect(setenv(stateEnvironmentKey, stateURL.path, 1) == 0)
        defer {
            unsetenv(stateEnvironmentKey)
            try? FileManager.default.removeItem(at: stateURL)
            try? FileManager.default.removeItem(at: pidLogURL)
            try? FileManager.default.removeItem(at: cwdLogURL)
            try? FileManager.default.removeItem(at: pwdLogURL)
        }

        let client = CodexAppServerClient(
            initializeTimeoutSeconds: 1,
            readTimeoutSeconds: 0.2
        )
        let startedAt = Date()

        do {
            do {
                _ = try await client.readRateLimits(configuredExecutablePath: fixtureURL.path)
                Issue.record("The first synthetic read must time out")
            } catch let error as UsageError {
                #expect(error == .codexRequestTimedOut("account/rateLimits/read"))
            }

            let provider = CodexUsageProvider(
                configuredExecutablePath: fixtureURL.path,
                client: client
            )
            let snapshot = try await provider.fetch()
            #expect(snapshot.representativeWindow?.used.usedPercent == 42)
            #expect(snapshot.windows.first { $0.kind == .weeklyAll }?.used.usedPercent == 17)
            #expect(snapshot.planType == "synthetic")
            #expect(snapshot.sourceVersion == "agent-usage-bar-timeout-stub/success")

            await client.stop()
        } catch {
            await client.stop()
            throw error
        }

        let pids = try String(contentsOf: pidLogURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        #expect(pids.count == 2)
        #expect(Set(pids).count == 2)
        #expect(await waitUntilProcessesExit(pids))
        let workingDirectories = try String(contentsOf: cwdLogURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let reportedPWDs = try String(contentsOf: pwdLogURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let temporaryRoot = try ProviderProcessWorkingDirectory.canonicalURL(
            FileManager.default.temporaryDirectory
        ).path
        #expect(workingDirectories.count == 2)
        #expect(Set(workingDirectories).count == 2)
        #expect(reportedPWDs == workingDirectories)
        #expect(workingDirectories.allSatisfy { $0 != "/" && $0.hasPrefix(temporaryRoot + "/") })
        #expect(workingDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(Date().timeIntervalSince(startedAt) < 10)
    }

    @Test("timeout hard-stops an App Server that ignores SIGTERM")
    func timeoutHardStopsTermResistantProcess() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-resistant-stub")
        #expect(FileManager.default.isExecutableFile(atPath: fixtureURL.path))

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-codex-resistant-\(UUID().uuidString)")
        let pidLogURL = URL(fileURLWithPath: stateURL.path + ".pids")
        #expect(setenv(stateEnvironmentKey, stateURL.path, 1) == 0)
        defer {
            unsetenv(stateEnvironmentKey)
            try? FileManager.default.removeItem(at: stateURL)
            try? FileManager.default.removeItem(at: pidLogURL)
        }

        let client = CodexAppServerClient(
            initializeTimeoutSeconds: 1,
            readTimeoutSeconds: 0.2,
            terminationGraceSeconds: 0.2
        )

        do {
            _ = try await client.readRateLimits(configuredExecutablePath: fixtureURL.path)
            Issue.record("The synthetic read must time out")
        } catch let error as UsageError {
            #expect(error == .codexRequestTimedOut("account/rateLimits/read"))
        }

        let pid = try #require(
            String(contentsOf: pidLogURL, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
                .first
        )
        #expect(await waitUntilProcessesExit([pid]))
        await client.stop()
    }

    @Test("stop returns only after a TERM-resistant owned process exits")
    func stopWaitsForTermResistantProcess() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-resistant-stub")
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-codex-stop-\(UUID().uuidString)")
        let pidLogURL = URL(fileURLWithPath: stateURL.path + ".pids")
        #expect(setenv(stateEnvironmentKey, stateURL.path, 1) == 0)
        defer {
            unsetenv(stateEnvironmentKey)
            try? FileManager.default.removeItem(at: stateURL)
            try? FileManager.default.removeItem(at: pidLogURL)
        }

        let client = CodexAppServerClient(
            initializeTimeoutSeconds: 1,
            readTimeoutSeconds: 30,
            terminationGraceSeconds: 0.2
        )
        let read = Task {
            try await client.readRateLimits(configuredExecutablePath: fixtureURL.path)
        }
        defer { read.cancel() }

        let pidDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidLogURL.path), Date() < pidDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(
            String(contentsOf: pidLogURL, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
                .first
        )

        await client.stop()
        #expect(!processExists(pid))
        _ = try? await read.value
    }

    private func waitUntilProcessesExit(_ pids: [Int32]) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if pids.allSatisfy({ !processExists($0) }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return pids.allSatisfy { !processExists($0) }
    }

    private func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
