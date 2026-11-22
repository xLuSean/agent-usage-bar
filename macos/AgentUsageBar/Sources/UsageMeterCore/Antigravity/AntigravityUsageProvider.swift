import Foundation

/// The live Antigravity path: run `agy`'s fixed, read-only `/usage` command and decode
/// its structured JSON output.
public struct AntigravityUsageProvider: UsageProvider {
    private let locator: AntigravityExecutableLocator
    private let runner: any AntigravityCommandRunning
    private let now: @Sendable () -> Date

    public init(
        locator: AntigravityExecutableLocator = AntigravityExecutableLocator(),
        runner: any AntigravityCommandRunning = AntigravityProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let executable = try locator.locate()

        let output = try await runner.run(
            executable: executable,
            arguments: AntigravityUsageCommand.arguments,
            timeout: AntigravityUsageCommand.timeout
        )

        guard output.exitCode == 0 else {
            throw Self.classify(output: output)
        }

        return try AntigravityUsageDecoder.decode(
            output.standardOutput,
            now: now()
        )
    }

    /// Classifies a non-zero CLI exit without leaking raw stderr/stdout into UI or logs.
    static func classify(output: AntigravityCommandOutput) -> UsageError {
        let stdoutPrefix = String(data: output.standardOutput.prefix(2048), encoding: .utf8) ?? ""
        let text = (output.standardErrorPrefix + " " + stdoutPrefix).lowercased()

        let unsupportedMarkers = [
            "unknown flag", "flag provided but not defined",
            "unknown option", "unrecognized option", "unknown argument",
            "no such option", "invalid option",
        ]
        if unsupportedMarkers.contains(where: text.contains) {
            return .antigravityVersionUnsupported("This build did not accept the read-only usage query.")
        }

        let signInMarkers = [
            "not logged in", "not signed in", "please log in", "please sign in",
            "unauthenticated", "authentication required", "unauthorized", "no credentials",
        ]
        if signInMarkers.contains(where: text.contains) {
            return .antigravityNotSignedIn
        }

        let offlineMarkers = [
            "no such host", "network is unreachable", "dial tcp",
            "connection refused", "offline", "dns",
        ]
        if offlineMarkers.contains(where: text.contains) {
            return .offline
        }

        return .antigravityCommandFailed("Antigravity CLI exited with status \(output.exitCode)")
    }
}
