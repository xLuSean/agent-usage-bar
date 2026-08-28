import Foundation
import Testing
@testable import UsageMeterCore

/// The only tests that start real processes — and none of them is `claude`.
///
/// Everything else in this suite injects a stub runner, which is right for asserting
/// behaviour but leaves `ClaudeProcessRunner` itself completely uncovered: the pipe
/// draining, the timeout watchdog, the terminate path. That is the same category of
/// code as the `MainActor.assumeIsolated` bug that reached a shipped build — concurrency
/// glue that compiles cleanly and fails only when actually run.
///
/// Standard system binaries stand in for the CLI. They are present on every macOS this
/// app supports, they behave identically everywhere, and they touch no account.
@Suite("子程序執行器（真的啟動程序）", .serialized)
struct ClaudeProcessRunnerTests {

    private struct ProcessContext: Decodable {
        let cwd: String
        let pwd: String?
        let entries: [String]
    }

    let runner = ClaudeProcessRunner()

    @Test("捕捉 stdout 與正常結束")
    func capturesStandardOutput() async throws {
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 10
        )

        #expect(output.exitCode == 0)
        #expect(String(data: output.standardOutput, encoding: .utf8) == "hello\n")
    }

    @Test("非零 exit 會如實回報")
    func reportsNonZeroExit() async throws {
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: 10
        )
        #expect(output.exitCode != 0)
    }

    /// stdin is `/dev/null`, so a command that reads until EOF must finish immediately.
    /// Inheriting a terminal here would leave a one-shot query waiting for input forever.
    @Test("stdin 是 /dev/null，讀取端不會卡住")
    func closesStandardInput() async throws {
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            timeout: 10
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.isEmpty)
    }

    /// Exercises the watchdog, the terminate path, and the drain-past-the-limit path all
    /// at once: `yes` never stops on its own and never stops writing. If the sink stopped
    /// reading at the cap instead of discarding, the child would block on a full pipe and
    /// this test would hang rather than fail.
    @Test("逾時會終止子程序並回報，不會卡住")
    func terminatesOnTimeout() async {
        let started = Date()
        await #expect(throws: UsageError.claudeCommandTimedOut) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                timeout: 1
            )
        }
        // Generous, but it fails outright if the watchdog never fires.
        #expect(Date().timeIntervalSince(started) < 20)
    }

    /// The cap exists so a CLI that decides to stream something unexpected cannot grow
    /// this app's memory without bound.
    @Test("輸出超過上限時截斷，但仍讀到結束")
    func capsOversizedOutput() async throws {
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            // 2 MB, comfortably past the 512 KB cap.
            arguments: ["if=/dev/zero", "bs=1024", "count=2000"],
            timeout: 30
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.count == ClaudeUsageCommand.maxOutputBytes)
    }

    @Test("無法啟動時回報 claudeCommandFailed，不是當機")
    func reportsAnUnlaunchableExecutable() async {
        await #expect(throws: UsageError.self) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/etc/hosts"),
                arguments: [],
                timeout: 5
            )
        }
    }

    /// The real command, run against a stand-in binary: proves the fixed argument list
    /// survives the trip through `Process` unchanged.
    @Test("固定的 arguments 原封不動傳給子程序")
    func passesTheApprovedArgumentsThrough() async throws {
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ClaudeUsageCommand.arguments,
            timeout: 10
        )

        let echoed = String(data: output.standardOutput, encoding: .utf8) ?? ""
        #expect(echoed.trimmingCharacters(in: .whitespacesAndNewlines)
            == ClaudeUsageCommand.arguments.joined(separator: " "))
    }

    @Test("子程序從空白的私人暫存目錄執行，PWD 與實際目錄一致")
    func usesAnIsolatedLocalWorkingDirectory() async throws {
        let output = try await runner.run(
            executable: fixtureURL,
            arguments: ["report-context"],
            timeout: 10
        )
        let context = try JSONDecoder().decode(ProcessContext.self, from: output.standardOutput)
        let temporaryRoot = try ProviderProcessWorkingDirectory.canonicalURL(
            FileManager.default.temporaryDirectory
        ).path

        #expect(context.cwd != "/")
        #expect(context.cwd.hasPrefix(temporaryRoot + "/"))
        #expect(context.pwd == context.cwd)
        #expect(context.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: context.cwd))
    }

    @Test("adopt 前取消也會在 child 報到後立刻生效")
    func remembersCancellationBeforeAdoption() async {
        let gate = AdoptionGate()
        let gatedRunner = ClaudeProcessRunner {
            gate.arriveAndWait()
        }
        let task = Task {
            try await gatedRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                timeout: 0.2
            )
        }
        defer {
            task.cancel()
            gate.open()
        }

        guard gate.waitUntilArrived() else {
            Issue.record("Synthetic child never reached the pre-adoption gate")
            return
        }
        task.cancel()
        gate.open()

        do {
            _ = try await task.value
            Issue.record("A cancelled run must not return command output")
        } catch is CancellationError {
            // Expected: cancellation remains the first terminal reason.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("忽略 SIGTERM 的 child 仍受 hard deadline 約束")
    func forceStopsAChildThatIgnoresTermination() async throws {
        #expect(FileManager.default.isExecutableFile(atPath: fixtureURL.path))
        let stateURL = temporaryStateURL("resistant")

        let started = Date()
        await #expect(throws: UsageError.claudeCommandTimedOut) {
            try await runner.run(
                executable: fixtureURL,
                arguments: ["ignore-term", stateURL.path],
                timeout: 1
            )
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await requestFixtureCleanup(at: stateURL))
    }

    @Test("descendant 持有 pipe 也不能讓查詢永遠等待")
    func closesPipesHeldByADescendant() async throws {
        #expect(FileManager.default.isExecutableFile(atPath: fixtureURL.path))
        let stateURL = temporaryStateURL("descendant")

        let started = Date()
        await #expect(throws: UsageError.claudeCommandTimedOut) {
            try await runner.run(
                executable: fixtureURL,
                arguments: ["descendant-holds-pipe", stateURL.path],
                timeout: 1
            )
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await requestFixtureCleanup(at: stateURL))
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-process-runner-stub")
    }

    private func temporaryStateURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-claude-\(label)-\(UUID().uuidString).state")
    }

    /// The random state path is the capability: only this test and its fixture know it.
    /// Cleanup never reads a PID or sends a signal, so PID reuse cannot target an
    /// unrelated process. The fixture also has a ten-second self-expiry for test aborts.
    private func requestFixtureCleanup(at stateURL: URL) async -> Bool {
        let stopURL = URL(fileURLWithPath: stateURL.path + ".stop")
        let doneURL = URL(fileURLWithPath: stateURL.path + ".done")
        try? Data("stop\n".utf8).write(to: stopURL, options: .atomic)

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: doneURL.path), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let completed = FileManager.default.fileExists(atPath: doneURL.path)
        for url in [stateURL, stopURL, doneURL] {
            try? FileManager.default.removeItem(at: url)
        }
        return completed
    }
}

private final class AdoptionGate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func arriveAndWait() {
        arrived.signal()
        release.wait()
    }

    func waitUntilArrived() -> Bool {
        arrived.wait(timeout: .now() + 2) == .success
    }

    func open() {
        release.signal()
    }
}
