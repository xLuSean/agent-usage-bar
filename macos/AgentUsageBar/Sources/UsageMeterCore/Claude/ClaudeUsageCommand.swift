import Darwin
import Foundation
import os

/// The one command this app is allowed to run.
///
/// # Why the arguments are a constant and not a parameter
///
/// This app previously read the OAuth credential out of the keychain and called an
/// undocumented endpoint itself. That is gone (see `docs/LEGACY_KEYCHAIN_PATH.md`).
/// What replaces it is asking Claude Code for a figure it already knows — which means
/// the app now *executes* something, and the blast radius of "executes something" is
/// decided entirely by whether the argument list can vary.
///
/// It cannot. `arguments` is a `let` on an enum with no initialiser, there is no
/// setting that feeds it, and no response can influence it. `verify.sh` fails the build
/// if any other file in `Claude/` constructs a `Process`, and if this list ever grows
/// `doctor`, `mcp`, `auth`, either billing-mutating credits command, or a shell.
///
/// The distinction that matters, and the one this project got wrong once: `/usage` is a
/// documented, read-only slash command whose whole purpose is to report this number.
/// An earlier maintenance command was invoked for an authentication side effect it
/// never promised and damaged the user's login state. Running a command for what it
/// documents is not the same act as running one for what it happens to do.
public enum ClaudeUsageCommand {

    /// Verified 2026-08-24 against Claude Code 2.1.231: returns `is_error=false`,
    /// `num_turns=0`, every token count `0`, `total_cost_usd=0`. No inference runs.
    ///
    /// - `--safe-mode` keeps hooks, plugins, MCP servers and project settings out of
    ///   the run while still using the existing sign-in.
    /// - `--no-session-persistence` stops the one-shot invocation leaving a session
    ///   behind. The response still carries a `session_id`; it is never stored.
    public static let arguments = [
        "--safe-mode",
        "--no-session-persistence",
        "-p", "/usage",
        "--output-format", "json",
    ]

    /// Generous: observed warm invocations finish well below one second, but a cold
    /// `node` start, a first run after an update, or a slow link is legitimately slower.
    /// The point of the ceiling is to bound a hang, not to police latency.
    public static let timeout: TimeInterval = 30

    /// A cooperative child gets a brief chance to flush and exit after SIGTERM. The
    /// operation is hard-bounded after this grace period even if the root ignores the
    /// signal or a descendant keeps an inherited output pipe open.
    static let terminationGrace: TimeInterval = 1

    /// `/usage` output ran ~1.5 KB in practice. The cap exists so a CLI that decides to
    /// stream something unexpected cannot grow the app's memory without bound.
    public static let maxOutputBytes = 512 * 1024

    /// stderr is read only to keep the child from blocking on a full pipe, and only a
    /// short prefix is kept. It is never surfaced: a CLI diagnostic can name paths,
    /// project directories, or a token, and none of that belongs in a UI or a log.
    static let maxStandardErrorBytes = 4 * 1024
}

/// What a finished run produced. Deliberately not `Codable` — nothing here is persisted.
public struct ClaudeCommandOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    /// Truncated, and for classification only (e.g. spotting "unknown option").
    public let standardErrorPrefix: String

    public init(exitCode: Int32, standardOutput: Data, standardErrorPrefix: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardErrorPrefix = standardErrorPrefix
    }
}

/// Injected so tests never launch a real CLI.
public protocol ClaudeCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ClaudeCommandOutput
}

/// The real one. This is the only place in `Claude/` that constructs a `Process`.
public struct ClaudeProcessRunner: ClaudeCommandRunning {
    private let beforeAdoptingProcess: @Sendable () -> Void

    public init() {
        beforeAdoptingProcess = {}
    }

    /// Test seam for deterministically cancelling after launch but before ownership is
    /// published to `ProcessHandle`. Production always uses the no-op public initializer.
    init(beforeAdoptingProcess: @escaping @Sendable () -> Void) {
        self.beforeAdoptingProcess = beforeAdoptingProcess
    }

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ClaudeCommandOutput {
        let workingDirectory: ProviderProcessWorkingDirectory
        do {
            workingDirectory = try ProviderProcessWorkingDirectory.create(for: .claude)
        } catch {
            throw UsageError.claudeCommandFailed(
                "Could not create an isolated local working directory."
            )
        }
        defer { workingDirectory.remove() }

        let handle = ProcessHandle(terminationGrace: ClaudeUsageCommand.terminationGrace)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.launchAndWait(
                        executable: executable,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        timeout: timeout,
                        handle: handle,
                        beforeAdoptingProcess: beforeAdoptingProcess,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            handle.requestStop(.cancelled)
        }
    }

    private static func launchAndWait(
        executable: URL,
        arguments: [String],
        workingDirectory: ProviderProcessWorkingDirectory,
        timeout: TimeInterval,
        handle: ProcessHandle,
        beforeAdoptingProcess: @Sendable () -> Void,
        continuation: CheckedContinuation<ClaudeCommandOutput, Error>
    ) {
        if handle.cancellationWasRequested {
            _ = handle.finish()
            continuation.resume(throwing: CancellationError())
            return
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.url
        // No stdin. A one-shot read must never be able to sit waiting for input, and
        // an inherited terminal would let it.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = Self.childEnvironment(workingDirectory: workingDirectory)

        do {
            try process.run()
        } catch {
            let stopReason = handle.finish()
            if stopReason == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(
                    throwing: UsageError.claudeCommandFailed(
                        "Could not run \(executable.lastPathComponent): \(error.localizedDescription)"
                    )
                )
            }
            return
        }
        beforeAdoptingProcess()
        handle.adopt(
            process,
            readHandles: [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
        )

        // Both pipes are drained concurrently with the wait. Reading only after exit
        // deadlocks the moment output exceeds the pipe buffer, which is a bug that hides
        // until the day the output grows.
        let group = DispatchGroup()
        let outputSink = ByteSink(limit: ClaudeUsageCommand.maxOutputBytes)
        let errorSink = ByteSink(limit: ClaudeUsageCommand.maxStandardErrorBytes)

        for (pipe, sink) in [(standardOutput, outputSink), (standardError, errorSink)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.drain(pipe.fileHandleForReading)
                group.leave()
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            handle.requestStop(.timedOut)
        }

        process.waitUntilExit()
        group.wait()

        switch handle.finish() {
        case .timedOut:
            continuation.resume(throwing: UsageError.claudeCommandTimedOut)
            return
        case .cancelled:
            continuation.resume(throwing: CancellationError())
            return
        case nil:
            break
        }

        continuation.resume(
            returning: ClaudeCommandOutput(
                exitCode: process.terminationStatus,
                standardOutput: outputSink.data,
                standardErrorPrefix: errorSink.string
            )
        )
    }

    /// Inherits the user's environment so `claude` can find its runtime and its own
    /// config, with the message locale pinned.
    ///
    /// The pin is insurance, not the mechanism. Measured 2026-08-26: running the command
    /// with `LANG=zh_TW.UTF-8 LC_ALL=zh_TW.UTF-8` returned the same English text, so
    /// `/usage` does not consult the locale environment at all today. That rules out one
    /// variable — it does not prove the text will never be localised, only that these
    /// variables are not how it would happen (a config setting or an account language
    /// preference would be).
    ///
    /// So the pin stays: two lines that cost nothing and would help if the CLI ever does
    /// honour them. What actually protects the reading is the parser, which fails closed
    /// on text it does not recognise rather than trusting the environment.
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: ProviderProcessWorkingDirectory? = nil
    ) -> [String: String] {
        var environment = base
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        return workingDirectory?.environment(basedOn: environment) ?? environment
    }
}

/// Shared mutable state between the waiting thread, the timeout, and cancellation.
private final class ProcessHandle: @unchecked Sendable {
    enum StopReason: Equatable {
        case cancelled
        case timedOut
    }

    private struct StopAction {
        let process: Process
    }

    private let terminationGrace: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var process: Process?
        var readHandles: [FileHandle] = []
        var stopReason: StopReason?
        var stopSequenceStarted = false
        var finished = false
    }

    init(terminationGrace: TimeInterval) {
        self.terminationGrace = terminationGrace
    }

    var cancellationWasRequested: Bool {
        state.withLock { $0.stopReason == .cancelled }
    }

    func adopt(_ process: Process, readHandles: [FileHandle]) {
        let action: StopAction? = state.withLock { state in
            guard !state.finished else { return nil }
            state.process = process
            state.readHandles = readHandles
            return startStopSequenceIfNeeded(state: &state)
        }
        perform(action)
    }

    /// The first terminal reason wins. Cancellation can arrive before `adopt`; the
    /// pending reason remains in state and starts the stop sequence as soon as the exact
    /// owned process is published.
    func requestStop(_ reason: StopReason) {
        let action: StopAction? = state.withLock { state in
            guard !state.finished else { return nil }
            if state.stopReason == nil {
                state.stopReason = reason
            }
            return startStopSequenceIfNeeded(state: &state)
        }
        perform(action)
    }

    /// Marks the operation complete and returns the first stop reason, if any. A later
    /// watchdog becomes a no-op and cannot turn a successful run into a timeout.
    func finish() -> StopReason? {
        state.withLock { state in
            state.finished = true
            let reason = state.stopReason
            state.process = nil
            state.readHandles = []
            return reason
        }
    }

    private func startStopSequenceIfNeeded(state: inout State) -> StopAction? {
        guard state.stopReason != nil,
              !state.stopSequenceStarted,
              let process = state.process else { return nil }
        state.stopSequenceStarted = true
        return StopAction(process: process)
    }

    /// Only ever acts on the exact `Process` instance adopted by this run — never a
    /// search for other `claude` processes the user may be running themselves.
    private func perform(_ action: StopAction?) {
        guard let action else { return }
        if action.process.isRunning {
            action.process.terminate()
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) {
            self.enforceHardStop()
        }
    }

    private func enforceHardStop() {
        let resources: (process: Process?, readHandles: [FileHandle])? = state.withLock { state in
            guard !state.finished, state.stopReason != nil else { return nil }
            let resources = (state.process, state.readHandles)
            // The hard stop owns closing these read ends. Drain workers tolerate the
            // resulting read error and leave their DispatchGroup exactly once.
            state.readHandles = []
            return resources
        }
        guard let resources else { return }

        // `Process` has no force-terminate API. The PID comes from this run's exact
        // still-running Process instance and is used immediately; no process scan or
        // process-group signal is ever performed.
        if let process = resources.process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        for readHandle in resources.readHandles {
            try? readHandle.close()
        }
    }
}

/// Reads a handle to EOF, keeping at most `limit` bytes.
///
/// Draining continues past the limit rather than stopping: a reader that stops reading
/// blocks the writer, and a blocked child never exits.
private final class ByteSink: @unchecked Sendable {
    private let limit: Int
    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data { buffer.withLock { $0 } }

    var string: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 64 * 1024), !next.isEmpty else {
                    break
                }
                chunk = next
            } catch {
                // The hard-deadline path closes this read end from another queue so a
                // descendant cannot hold the operation open. That expected EBADF-style
                // read failure is the drain's termination signal.
                break
            }

            buffer.withLock { buffer in
                let room = limit - buffer.count
                if room > 0 {
                    buffer.append(chunk.prefix(room))
                }
            }
        }
        try? handle.close()
    }
}
