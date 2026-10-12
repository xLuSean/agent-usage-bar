import Foundation

/// The live Claude path: ask Claude Code for the figure it already reports.
///
/// # What changed in 0.3.0, and why
///
/// This used to read the OAuth credential out of the macOS keychain and call an
/// undocumented endpoint with the CLI's own User-Agent. It worked, and it cost the
/// user a keychain dialog that came back every eight hours, a credential the app had
/// no business holding, and a wire identity indistinguishable from the official
/// client. `docs/LEGACY_KEYCHAIN_PATH.md` records that path in full, including the
/// conditions under which returning to it would be justified.
///
/// What runs instead is one fixed, documented, read-only command. The app never sees a
/// token. It also never signs anything in: when Claude Code is not signed in, the app
/// says so and offers the command to copy, and the user runs it themselves.
///
/// # The honest caveat
///
/// The prose `/usage` prints comes from Claude Code's local cache when it cannot reach
/// the server — verified by running it with the network off — and carries no as-of
/// time. The structured report attached to the same output says so instead, with no
/// rows, and `ClaudeUsageDecoder` reports that rather than the cached figures.
///
/// Where no report is attached, an older CLI for instance, the prose is all there is.
/// The reset time then bounds how old it can be, and the residual exposure is staleness
/// within a single window. That remains a real trade against the old path.
public struct ClaudeUsageProvider: UsageProvider {
    private let locator: ClaudeExecutableLocator
    private let runner: any ClaudeCommandRunning
    private let now: @Sendable () -> Date

    public init(
        locator: ClaudeExecutableLocator = ClaudeExecutableLocator(),
        runner: any ClaudeCommandRunning = ClaudeProcessRunner(),
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
            // Never assembled, never configurable, never influenced by a response.
            arguments: ClaudeUsageCommand.arguments,
            timeout: ClaudeUsageCommand.timeout
        )

        guard output.exitCode == 0 else {
            throw Self.classify(output: output)
        }

        return try ClaudeUsageDecoder.decode(
            output.standardOutput,
            now: now(),
            sourceVersion: ClaudeExecutableLocator.detectedVersion(at: executable)
        )
    }

    /// Turns a failed run into the error whose remedy actually helps.
    ///
    /// The CLI's own output is read **only to classify**. Nothing from it reaches the
    /// returned error, the UI, or a log: a CLI diagnostic can name working directories,
    /// project paths, or a credential, and a generic message plus the right next step is
    /// worth more to the user than a verbatim dump would be anyway.
    static func classify(output: ClaudeCommandOutput) -> UsageError {
        let text = (output.standardErrorPrefix + " " + Self.classificationText(of: output.standardOutput))
            .lowercased()

        // Checked before sign-in markers: an old build rejecting `--safe-mode` often
        // prints usage text that mentions logging in, and "update Claude Code" is the
        // step that actually fixes it.
        let unsupportedMarkers = [
            "unknown option", "unrecognized option", "unknown argument",
            "no such option", "unknown command", "invalid option",
        ]
        if unsupportedMarkers.contains(where: text.contains) {
            return .claudeVersionUnsupported("This build did not accept the read-only usage query.")
        }

        let signInMarkers = [
            "not logged in", "not signed in", "please log in", "please sign in",
            "authentication", "unauthorized", "no credentials",
        ]
        if signInMarkers.contains(where: text.contains) {
            return .claudeNotSignedIn
        }

        return .claudeCommandFailed("Claude Code exited with status \(output.exitCode)")
    }

    /// What the CLI said about the failure, bounded, for classification only.
    ///
    /// With `--verbose` stdout is an array whose first message lists the run's tools,
    /// commands and plugins. Reading a prefix of that would miss the outcome, which
    /// comes last, and could match a marker against a tool's name instead. So when the
    /// output is that array, only the `result` messages' own text is considered.
    private static func classificationText(of data: Data) -> String {
        if let messages = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            let outcome = messages
                .compactMap { $0 as? [String: Any] }
                .filter { $0["type"] as? String == "result" }
                .compactMap { $0["result"] as? String }
                .joined(separator: " ")
            return String(outcome.prefix(2048))
        }
        return String(data: data.prefix(2048), encoding: .utf8) ?? ""
    }
}
