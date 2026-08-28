import Foundation
import Testing
@testable import UsageMeterCore

/// Nothing here launches a real CLI. The runner is injected precisely so the argument
/// list, the failure classification, and the decode path can all be asserted without a
/// process, a credential, or a network.
struct ClaudeProviderTests {

    // MARK: - Doubles

    /// Records what it was asked to run, then answers with a canned result.
    final class RecordingRunner: ClaudeCommandRunning, @unchecked Sendable {
        private(set) var executable: URL?
        private(set) var arguments: [String] = []
        private(set) var timeout: TimeInterval = 0
        private(set) var runCount = 0
        let result: Result<ClaudeCommandOutput, any Error>

        init(result: Result<ClaudeCommandOutput, any Error>) {
            self.result = result
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ClaudeCommandOutput {
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
            runCount += 1
            return try result.get()
        }
    }

    static let now = Date(timeIntervalSince1970: 1_787_576_400)

    static func successOutput(sessionPercent: Int = 42) -> ClaudeCommandOutput {
        ClaudeCommandOutput(
            exitCode: 0,
            standardOutput: ClaudeUsageTextDecoderTests.envelope(
                ClaudeUsageTextDecoderTests.body(
                    session: "\(sessionPercent)% used · resets Aug 25 at 1am (Asia/Taipei)"
                )
            )
        )
    }

    /// `/bin/echo` exists and is executable everywhere this runs; the stub runner never
    /// actually invokes it.
    static func locator() -> ClaudeExecutableLocator {
        ClaudeExecutableLocator(configuredPath: "/bin/echo", environment: [:])
    }

    // MARK: - The command is fixed

    /// The single most important assertion in this file. If the argument list can drift,
    /// every guarantee about this app being read-only drifts with it.
    @Test func runsExactlyTheApprovedArguments() async throws {
        let runner = RecordingRunner(result: .success(Self.successOutput()))
        let provider = ClaudeUsageProvider(locator: Self.locator(), runner: runner, now: { Self.now })

        _ = try await provider.fetch()

        #expect(runner.arguments == [
            "--safe-mode", "--no-session-persistence", "-p", "/usage", "--output-format", "json",
        ])
        #expect(runner.arguments == ClaudeUsageCommand.arguments)
        #expect(runner.timeout == ClaudeUsageCommand.timeout)
        #expect(runner.runCount == 1)
    }

    @Test func neverRunsARenewalOrSignInCommand() {
        let forbidden = [
            "doctor", "mcp", "auth", "login", "logout", "setup-token", "update",
            "usage-credits", "/usage-credits", "extra-usage", "/extra-usage",
            "-c", "--continue",
        ]
        for argument in ClaudeUsageCommand.arguments {
            #expect(!forbidden.contains(argument), "\(argument) must not be part of the usage query")
        }
        #expect(ClaudeUsageCommand.arguments.contains("/usage"))
    }

    @Test func decodesASuccessfulRun() async throws {
        let runner = RecordingRunner(result: .success(Self.successOutput(sessionPercent: 63)))
        let provider = ClaudeUsageProvider(locator: Self.locator(), runner: runner, now: { Self.now })

        let snapshot = try await provider.fetch()

        #expect(snapshot.provider == .claude)
        #expect(snapshot.sourcePath == .claudeCodeCLI)
        #expect(snapshot.representativeWindow?.used.usedPercent == 63)
        #expect(snapshot.fetchedAt == Self.now)
    }

    // MARK: - Locating the executable

    @Test func reportsAnExplicitPathThatIsNotExecutable() async {
        let provider = ClaudeUsageProvider(
            locator: ClaudeExecutableLocator(configuredPath: "/etc/hosts", environment: [:]),
            runner: RecordingRunner(result: .success(Self.successOutput())),
            now: { Self.now }
        )
        await #expect(throws: UsageError.claudeExecutableInvalid("/etc/hosts")) {
            try await provider.fetch()
        }
    }

    @Test func reportsAMissingExecutableWhenAutoDetecting() throws {
        let locator = ClaudeExecutableLocator(
            configuredPath: nil,
            environment: [:],
            commonCandidatePaths: ["/nonexistent/claude"]
        )
        #expect(throws: UsageError.claudeExecutableNotFound) {
            try locator.locate()
        }
    }

    /// A GUI app's PATH is not the shell's, so the known install locations have to be
    /// tried before it — but PATH still has to be tried, for unusual installs.
    @Test func searchesKnownLocationsBeforePath() {
        let locator = ClaudeExecutableLocator(
            configuredPath: nil,
            environment: ["PATH": "/somewhere/bin"],
            commonCandidatePaths: ["/opt/homebrew/bin/claude"]
        )
        #expect(locator.candidatePaths == ["/opt/homebrew/bin/claude", "/somewhere/bin/claude"])
    }

    @Test func honoursTheDevelopmentOverrideFirst() {
        let locator = ClaudeExecutableLocator(
            configuredPath: nil,
            environment: ["CLAUDE_EXECUTABLE": "/custom/claude", "PATH": "/somewhere/bin"],
            commonCandidatePaths: ["/opt/homebrew/bin/claude"]
        )
        #expect(locator.candidatePaths.first == "/custom/claude")
    }

    // MARK: - Classifying failures

    @Test func classifiesAnOldBuildAsUnsupported() {
        let output = ClaudeCommandOutput(
            exitCode: 1,
            standardOutput: Data(),
            standardErrorPrefix: "error: unknown option '--safe-mode'"
        )
        guard case .claudeVersionUnsupported = ClaudeUsageProvider.classify(output: output) else {
            Issue.record("Expected claudeVersionUnsupported")
            return
        }
    }

    @Test func classifiesASignedOutCLI() {
        let output = ClaudeCommandOutput(
            exitCode: 1,
            standardOutput: Data(),
            standardErrorPrefix: "You are not logged in. Please sign in to continue."
        )
        #expect(ClaudeUsageProvider.classify(output: output) == .claudeNotSignedIn)
    }

    /// Version markers win: an old build rejecting the flag often prints usage text that
    /// also mentions signing in, and "update Claude Code" is the step that fixes it.
    @Test func prefersTheUnsupportedDiagnosisWhenBothMarkersAppear() {
        let output = ClaudeCommandOutput(
            exitCode: 1,
            standardOutput: Data(),
            standardErrorPrefix: "unknown option '--safe-mode'. Run `claude` to log in."
        )
        guard case .claudeVersionUnsupported = ClaudeUsageProvider.classify(output: output) else {
            Issue.record("Expected claudeVersionUnsupported to win")
            return
        }
    }

    @Test func fallsBackToAGenericFailure() {
        let output = ClaudeCommandOutput(exitCode: 9, standardOutput: Data(), standardErrorPrefix: "boom")
        guard case .claudeCommandFailed(let detail) = ClaudeUsageProvider.classify(output: output) else {
            Issue.record("Expected claudeCommandFailed")
            return
        }
        // The CLI's own text is read to classify and then dropped: it can name project
        // paths, working directories, or a credential.
        #expect(!detail.contains("boom"))
        #expect(detail.contains("9"))
    }

    @Test func surfacesANonZeroExitFromFetch() async {
        let runner = RecordingRunner(
            result: .success(
                ClaudeCommandOutput(
                    exitCode: 1,
                    standardOutput: Data(),
                    standardErrorPrefix: "not logged in"
                )
            )
        )
        let provider = ClaudeUsageProvider(locator: Self.locator(), runner: runner, now: { Self.now })
        await #expect(throws: UsageError.claudeNotSignedIn) {
            try await provider.fetch()
        }
    }

    @Test func propagatesATimeout() async {
        let runner = RecordingRunner(result: .failure(UsageError.claudeCommandTimedOut))
        let provider = ClaudeUsageProvider(locator: Self.locator(), runner: runner, now: { Self.now })
        await #expect(throws: UsageError.claudeCommandTimedOut) {
            try await provider.fetch()
        }
    }

    // MARK: - Recovery guidance

    @Test func offersTheLaunchCommandOnlyWhenItWouldHelp() {
        #expect(ClaudeSignInRecovery.command(for: .claudeNotSignedIn) == "claude")
        // An install or an update is not something a copied `claude` can do.
        #expect(ClaudeSignInRecovery.command(for: .claudeExecutableNotFound) == nil)
        #expect(ClaudeSignInRecovery.command(for: .claudeVersionUnsupported("old")) == nil)
        #expect(ClaudeSignInRecovery.command(for: .claudeCommandTimedOut) == nil)
        #expect(ClaudeSignInRecovery.command(for: .offline) == nil)
        #expect(ClaudeSignInRecovery.command(for: nil) == nil)
    }

    // MARK: - Environment

    @Test func pinsTheChildLocaleWithoutDiscardingTheEnvironment() {
        let environment = ClaudeProcessRunner.childEnvironment(base: ["HOME": "/Users/example", "LANG": "zh_TW.UTF-8"])
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["LC_ALL"] == "en_US.UTF-8")
        // Stripping the environment would leave the CLI unable to find its runtime or
        // its own configuration.
        #expect(environment["HOME"] == "/Users/example")
    }

    // MARK: - Stored snapshots from earlier versions

    /// `UsageSnapshotStore` persists across launches, so the first run after an upgrade
    /// decodes a snapshot written by the HTTP path. Dropping the case would open the app
    /// with no data and no visible reason.
    @Test func stillDecodesRetiredSourcePaths() throws {
        for raw in ["usageEndpoint", "messagesFallback"] {
            let path = try #require(UsageSourcePath(rawValue: raw))
            #expect(path.isRetired)
        }
        #expect(UsageSourcePath.claudeCodeCLI.isRetired == false)
        #expect(UsageSourcePath.codexAppServer.isRetired == false)
    }
}
