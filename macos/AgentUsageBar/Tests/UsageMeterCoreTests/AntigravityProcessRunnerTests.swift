import Foundation
import Testing
@testable import UsageMeterCore

/// Starts real processes through `AntigravityProcessRunner`, never `agy` itself. The
/// shared Python stub stands in for the CLI; it ignores the `--log-file` pair the runner
/// appends. Every test passes its own base directory, so none of them touches the fixed
/// workspace that a running copy of the app may be using.
@Suite("Antigravity 子程序執行器（真的啟動程序）", .serialized)
struct AntigravityProcessRunnerTests {

    private struct ProcessContext: Decodable {
        let cwd: String
        let pwd: String?
        let entries: [String]
    }

    @Test("每次查詢重用同一個固定工作目錄，開始時空白、結束後移除")
    func reusesOneFixedWorkingDirectory() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = AntigravityProcessRunner(workspaceBaseDirectory: base)
        let expected = try ProviderProcessWorkingDirectory.preparedPrivateRoot(baseDirectory: base).root
            .appendingPathComponent(AntigravityUsageCommand.workspaceName, isDirectory: true)
            .path

        for _ in 0..<2 {
            let output = try await runner.run(
                executable: fixtureURL,
                arguments: ["report-context"],
                timeout: 10
            )
            let context = try JSONDecoder().decode(ProcessContext.self, from: output.standardOutput)

            #expect(context.cwd == expected)
            #expect(context.pwd == context.cwd)
            #expect(context.entries.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: context.cwd))
        }
    }

    @Test("另一個查詢持有鎖時短暫重試後回報可重試的失敗，不清空它的目錄")
    func reportsABusyWorkspaceInsteadOfClearingIt() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try ProviderProcessWorkingDirectory.preparedPrivateRoot(baseDirectory: base).root
        let held = try #require(try AntigravityWorkspaceLock.acquire(
            at: root.appendingPathComponent("\(AntigravityUsageCommand.workspaceName).lock")
        ))
        defer { held.release() }
        let inUse = root.appendingPathComponent(AntigravityUsageCommand.workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(at: inUse, withIntermediateDirectories: false)
        let marker = inUse.appendingPathComponent("agy.log")
        try Data("still being written\n".utf8).write(to: marker)

        let runner = AntigravityProcessRunner(
            workspaceBaseDirectory: base,
            workspaceLockAttempts: 3,
            workspaceLockRetryDelay: .milliseconds(20)
        )
        await #expect(throws: UsageError.antigravityCommandFailed("Another Antigravity usage query is still running")) {
            try await runner.run(executable: fixtureURL, arguments: ["report-context"], timeout: 10)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        held.release()
        let output = try await runner.run(executable: fixtureURL, arguments: ["report-context"], timeout: 10)
        #expect(output.exitCode == 0)
    }

    /// `agy` can leave the user's MCP servers running after it exits. A survivor that had
    /// inherited the lock descriptor would block every later query until it died.
    @Test("留在背景的子孫程序不會持有鎖，下一次查詢立即取得")
    func survivingDescendantDoesNotHoldTheWorkspaceLock() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let stateURL = temporaryStateURL("descendant")
        let runner = AntigravityProcessRunner(workspaceBaseDirectory: base, workspaceLockAttempts: 1)

        await #expect(throws: UsageError.antigravityCommandTimedOut) {
            try await runner.run(
                executable: fixtureURL,
                arguments: ["descendant-holds-pipe", stateURL.path],
                timeout: 1
            )
        }
        // The descendant is still alive here, waiting for its stop file.
        let output = try await runner.run(executable: fixtureURL, arguments: ["report-context"], timeout: 10)
        #expect(output.exitCode == 0)
        #expect(await requestFixtureCleanup(at: stateURL))
    }

    @Test("鎖檔描述符設定為執行時關閉，同一時間只有一個持有者")
    func workspaceLockIsExclusiveAndClosesOnExec() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let lockURL = try ProviderProcessWorkingDirectory.preparedPrivateRoot(baseDirectory: base).root
            .appendingPathComponent("\(AntigravityUsageCommand.workspaceName).lock")

        let first = try #require(try AntigravityWorkspaceLock.acquire(at: lockURL))
        #expect(first.closesOnExec)
        #expect(try AntigravityWorkspaceLock.acquire(at: lockURL) == nil)

        first.release()
        let second = try #require(try AntigravityWorkspaceLock.acquire(at: lockURL))
        second.release()
    }

    @Test("子程序環境固定關閉 agy 自動更新，值必須是 true")
    func childEnvironmentDisablesAutoUpdate() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let inherited = ["PATH": "/usr/bin", "AGY_CLI_DISABLE_AUTO_UPDATE": "0"]

        let plain = AntigravityProcessRunner.childEnvironment(base: inherited)
        #expect(plain["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
        #expect(plain["LANG"] == "en_US.UTF-8")
        #expect(plain["PATH"] == "/usr/bin")

        let directory = try ProviderProcessWorkingDirectory.createReusable(named: "env-probe", baseDirectory: base)
        defer { directory.remove() }
        let withDirectory = AntigravityProcessRunner.childEnvironment(base: inherited, workingDirectory: directory)
        #expect(withDirectory["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
        #expect(withDirectory["PWD"] == directory.url.path)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-process-runner-stub")
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        return base
    }

    private func temporaryStateURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-antigravity-\(label)-\(UUID().uuidString).state")
    }

    /// Same capability-file cleanup as the Claude runner tests: no PID is read or signalled.
    private func requestFixtureCleanup(at stateURL: URL) async -> Bool {
        let stopURL = URL(fileURLWithPath: stateURL.path + ".stop")
        let doneURL = URL(fileURLWithPath: stateURL.path + ".done")
        try? Data("stop\n".utf8).write(to: stopURL, options: .atomic)

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: doneURL.path), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let finished = FileManager.default.fileExists(atPath: doneURL.path)
        for url in [stateURL, stopURL, doneURL] {
            try? FileManager.default.removeItem(at: url)
        }
        return finished
    }
}
