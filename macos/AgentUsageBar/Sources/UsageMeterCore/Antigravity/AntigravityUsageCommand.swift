import Darwin
import Foundation
import os

/// The one Antigravity CLI command this app is allowed to run.
///
/// `arguments` is a fixed constant on a caseless enum — no user setting and no upstream
/// response can alter it. The CLI log file is redirected into the per-run isolated
/// working directory so each query cleans up after itself.
public enum AntigravityUsageCommand {

    /// Read-only `/usage` query in print mode.
    /// Verified against `agy`: returns `status="SUCCESS"`, `conversation_id=""`,
    /// `num_turns=0`, and zero token counts; runs no model inference and creates no
    /// conversation history.
    public static let arguments = [
        "-p", "/usage",
        "--output-format", "json",
        "--print-timeout", "15s",
    ]

    /// Outer hard watchdog above `--print-timeout 15s` so a clean CLI timeout finishes
    /// first while a hung process is still bounded.
    public static let timeout: TimeInterval = 30

    static let terminationGrace: TimeInterval = 1

    public static let maxOutputBytes = 512 * 1024

    static let maxStandardErrorBytes = 4 * 1024
}

/// Output of one finished `agy` invocation. Deliberately not `Codable`.
public struct AntigravityCommandOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    /// Truncated and for classification only; never surfaced to UI or persisted logs.
    public let standardErrorPrefix: String

    public init(exitCode: Int32, standardOutput: Data, standardErrorPrefix: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardErrorPrefix = standardErrorPrefix
    }
}

/// Injected so unit tests never launch a real CLI.
public protocol AntigravityCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> AntigravityCommandOutput
}

/// The live runner. This is the only file in `Antigravity/` allowed to construct a `Process`.
public struct AntigravityProcessRunner: AntigravityCommandRunning {
    private let beforeAdoptingProcess: @Sendable () -> Void

    public init() {
        beforeAdoptingProcess = {}
    }

    init(beforeAdoptingProcess: @escaping @Sendable () -> Void) {
        self.beforeAdoptingProcess = beforeAdoptingProcess
    }

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> AntigravityCommandOutput {
        let workingDirectory: ProviderProcessWorkingDirectory
        do {
            workingDirectory = try ProviderProcessWorkingDirectory.create(for: .antigravity)
        } catch {
            throw UsageError.antigravityCommandFailed(
                "Could not create an isolated local working directory."
            )
        }
        defer { workingDirectory.remove() }

        let handle = AntigravityProcessHandle(terminationGrace: AntigravityUsageCommand.terminationGrace)

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
        handle: AntigravityProcessHandle,
        beforeAdoptingProcess: @Sendable () -> Void,
        continuation: CheckedContinuation<AntigravityCommandOutput, Error>
    ) {
        if handle.cancellationWasRequested {
            _ = handle.finish()
            continuation.resume(throwing: CancellationError())
            return
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let logFilePath = workingDirectory.url.appendingPathComponent("agy.log").path

        process.executableURL = executable
        process.arguments = arguments + ["--log-file", logFilePath]
        process.currentDirectoryURL = workingDirectory.url
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
                    throwing: UsageError.antigravityCommandFailed(
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

        let group = DispatchGroup()
        let outputSink = AntigravityByteSink(limit: AntigravityUsageCommand.maxOutputBytes)
        let errorSink = AntigravityByteSink(limit: AntigravityUsageCommand.maxStandardErrorBytes)

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
            continuation.resume(throwing: UsageError.antigravityCommandTimedOut)
            return
        case .cancelled:
            continuation.resume(throwing: CancellationError())
            return
        case nil:
            break
        }

        continuation.resume(
            returning: AntigravityCommandOutput(
                exitCode: process.terminationStatus,
                standardOutput: outputSink.data,
                standardErrorPrefix: errorSink.string
            )
        )
    }

    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: ProviderProcessWorkingDirectory? = nil
    ) -> [String: String] {
        var environment = base
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        guard let workingDirectory else { return environment }
        return workingDirectory.environment(basedOn: environment)
    }
}

private final class AntigravityProcessHandle: @unchecked Sendable {
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
            state.readHandles = []
            return resources
        }
        guard let resources else { return }
        if let process = resources.process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        for readHandle in resources.readHandles {
            try? readHandle.close()
        }
    }
}

private final class AntigravityByteSink: @unchecked Sendable {
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
