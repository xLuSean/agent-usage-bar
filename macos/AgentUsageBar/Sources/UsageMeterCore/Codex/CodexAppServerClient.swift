import Darwin
import Foundation

public struct CodexAppServerRead: Sendable, Hashable {
    public let payload: Data
    public let serverUserAgent: String?

    public init(payload: Data, serverUserAgent: String?) {
        self.payload = payload
        self.serverUserAgent = serverUserAgent
    }
}

public protocol CodexAppServerReading: Sendable {
    func readRateLimits(configuredExecutablePath: String?) async throws -> CodexAppServerRead
    func readAccountUsage(configuredExecutablePath: String?) async throws -> CodexAppServerRead
}

public extension CodexAppServerReading {
    /// Keeps test doubles and older internal readers source-compatible. The provider treats
    /// this optional capability independently from the required rate-limit reading.
    func readAccountUsage(configuredExecutablePath: String?) async throws -> CodexAppServerRead {
        throw UsageError.codexVersionIncompatible(
            "The selected Codex App Server does not support account/usage/read."
        )
    }
}

/// The synchronous boundary between `FileHandle` callbacks and the client actor.
///
/// `readabilityHandler` may fire again before the actor has processed the previous
/// chunk. Retaining one Task per callback would put an unbounded queue *in front of*
/// the JSONL buffer's size limit. This ingress instead owns at most one consumer and
/// caps the bytes waiting for that consumer while preserving callback order.
final class CodexOutputIngress: @unchecked Sendable {
    struct EnqueueAction: Equatable, Sendable {
        let startConsumer: Bool
        let stopReading: Bool
    }

    enum Next: Equatable, Sendable {
        case chunk(Data)
        case overflow
        case empty
        case closed
    }

    private struct State {
        var buffer = Data()
        var consumerScheduled = false
        var overflowed = false
        var closed = false
    }

    private let maximumQueuedBytes: Int
    private let lock = NSLock()
    private var state = State()

    init(maximumQueuedBytes: Int = 4 * 1024 * 1024) {
        precondition(maximumQueuedBytes > 0)
        self.maximumQueuedBytes = maximumQueuedBytes
    }

    func enqueue(_ data: Data) -> EnqueueAction {
        guard !data.isEmpty else {
            return EnqueueAction(startConsumer: false, stopReading: false)
        }

        lock.lock()
        defer { lock.unlock() }

        guard !state.closed else {
            return EnqueueAction(startConsumer: false, stopReading: true)
        }

        guard data.count <= maximumQueuedBytes - state.buffer.count else {
            state.buffer.removeAll(keepingCapacity: false)
            state.overflowed = true
            state.closed = true
            let shouldStart = !state.consumerScheduled
            state.consumerScheduled = true
            return EnqueueAction(startConsumer: shouldStart, stopReading: true)
        }

        // Coalescing also bounds callback metadata: millions of one-byte callbacks
        // cannot create millions of queued Data objects under the byte limit.
        state.buffer.append(data)
        let shouldStart = !state.consumerScheduled
        state.consumerScheduled = true
        return EnqueueAction(startConsumer: shouldStart, stopReading: false)
    }

    func next() -> Next {
        lock.lock()
        defer { lock.unlock() }

        if state.overflowed {
            state.overflowed = false
            return .overflow
        }

        if !state.buffer.isEmpty {
            let chunk = state.buffer
            state.buffer = Data()
            return .chunk(chunk)
        }

        state.consumerScheduled = false
        return state.closed ? .closed : .empty
    }

    /// Invalidates this connection generation and releases queued bytes immediately.
    func close() {
        lock.lock()
        state.buffer.removeAll(keepingCapacity: false)
        state.overflowed = false
        state.closed = true
        lock.unlock()
    }
}

/// Owns one long-running `codex app-server` child process. The actor serializes request
/// IDs, writes, JSONL framing, and process replacement when the configured path changes.
public actor CodexAppServerClient: CodexAppServerReading {
    public static let shared = CodexAppServerClient()

    public nonisolated let rateLimitUpdates: AsyncStream<CodexAppServerRead>

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
    }

    private let updateContinuation: AsyncStream<CodexAppServerRead>.Continuation
    private let initializeTimeoutSeconds: TimeInterval
    private let readTimeoutSeconds: TimeInterval
    private let terminationGraceSeconds: TimeInterval
    private var process: Process?
    private var processWorkingDirectory: ProviderProcessWorkingDirectory?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputIngress: CodexOutputIngress?
    private var executableURL: URL?
    private var serverUserAgent: String?
    private var isReady = false
    private var isStarting = false
    private var startupWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var jsonl = CodexJSONLBuffer()
    private var generation = 0
    private var terminatingProcesses: [Int32: Process] = [:]
    private var terminatingWorkingDirectories: [Int32: ProviderProcessWorkingDirectory] = [:]
    private var terminationWaiters: [Int32: [CheckedContinuation<Void, Never>]] = [:]

    public init() {
        initializeTimeoutSeconds = 10
        readTimeoutSeconds = 15
        terminationGraceSeconds = 1
        let stream = AsyncStream.makeStream(
            of: CodexAppServerRead.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        rateLimitUpdates = stream.stream
        updateContinuation = stream.continuation
    }

    init(
        initializeTimeoutSeconds: TimeInterval,
        readTimeoutSeconds: TimeInterval,
        terminationGraceSeconds: TimeInterval = 1
    ) {
        precondition(
            initializeTimeoutSeconds > 0
                && readTimeoutSeconds > 0
                && terminationGraceSeconds > 0
        )
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        let stream = AsyncStream.makeStream(
            of: CodexAppServerRead.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        rateLimitUpdates = stream.stream
        updateContinuation = stream.continuation
    }

    public func readRateLimits(configuredExecutablePath: String?) async throws -> CodexAppServerRead {
        let requestedURL = try CodexExecutableLocator(configuredPath: configuredExecutablePath).locate()
        try await ensureConnected(to: requestedURL)
        let payload = try await sendRequest(
            .rateLimitsRead,
            params: nil,
            timeoutSeconds: readTimeoutSeconds
        )
        return CodexAppServerRead(payload: payload, serverUserAgent: serverUserAgent)
    }

    public func readAccountUsage(configuredExecutablePath: String?) async throws -> CodexAppServerRead {
        let requestedURL = try CodexExecutableLocator(configuredPath: configuredExecutablePath).locate()
        try await ensureConnected(to: requestedURL)
        let payload = try await sendRequest(
            .accountUsageRead,
            params: nil,
            timeoutSeconds: readTimeoutSeconds
        )
        return CodexAppServerRead(payload: payload, serverUserAgent: serverUserAgent)
    }

    /// Terminates only the process this client launched. Safe to call when stopped.
    public func stop() async {
        stopConnection(
            failingPendingWith: UsageError.codexAppServerUnavailable("Codex App Server was stopped by the app"),
            terminateProcess: true
        )
        // `stopConnection` starts every exact-root TERM -> hard-stop sequence. Do not
        // tell AppKit shutdown is complete until Foundation has observed those roots
        // exit; otherwise the task that sends SIGKILL can disappear with the host app.
        for pid in Array(terminatingProcesses.keys) {
            await waitForOwnedProcessToExit(pid: pid)
        }
    }

    private func ensureConnected(to requestedURL: URL) async throws {
        if isReady, process?.isRunning == true, executableURL == requestedURL { return }

        if isStarting {
            try await withCheckedThrowingContinuation { continuation in
                startupWaiters.append(continuation)
            }
            if isReady, executableURL == requestedURL { return }
            return try await ensureConnected(to: requestedURL)
        }

        if executableURL != nil, executableURL != requestedURL {
            stopConnection(
                failingPendingWith: UsageError.codexAppServerUnavailable("Codex CLI path changed"),
                terminateProcess: true
            )
        }

        isStarting = true
        do {
            try launch(executableURL: requestedURL)
            let initializeResult = try await sendRequest(
                .initialize,
                params: Self.initializeParams,
                timeoutSeconds: initializeTimeoutSeconds
            )
            serverUserAgent = Self.userAgent(fromInitializeResult: initializeResult)
            try write(CodexJSONRPC.notification(.initialized))
            isReady = true
            isStarting = false
            resumeStartupWaiters(with: nil)
        } catch {
            isStarting = false
            let usageError = (error as? UsageError) ?? .codexAppServerUnavailable(error.localizedDescription)
            stopConnection(failingPendingWith: usageError, terminateProcess: true)
            resumeStartupWaiters(with: usageError)
            throw usageError
        }
    }

    private static var initializeParams: [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return [
            "clientInfo": [
                "name": "agent_usage_bar",
                "title": "Agent Usage Bar",
                "version": version,
            ],
        ]
    }

    private static func userAgent(fromInitializeResult data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["userAgent"] as? String
    }

    private func launch(executableURL: URL) throws {
        generation += 1
        let launchedGeneration = generation
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let workingDirectory: ProviderProcessWorkingDirectory
        do {
            workingDirectory = try ProviderProcessWorkingDirectory.create(for: .codex)
        } catch {
            throw UsageError.codexAppServerUnavailable(
                "Could not create an isolated local working directory."
            )
        }

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = workingDirectory.url
        process.environment = workingDirectory.environment()
        process.standardInput = input
        process.standardOutput = output
        // Never let an unread stderr pipe fill and deadlock the child. The provider's
        // diagnostics use typed errors and exit status, not arbitrary upstream logs.
        process.standardError = FileHandle.nullDevice

        let ingress = CodexOutputIngress()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let action = ingress.enqueue(data)
            if action.stopReading {
                handle.readabilityHandler = nil
            }
            guard action.startConsumer else { return }
            Task { await self?.drainOutput(ingress, generation: launchedGeneration) }
        }
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { await self?.processDidExit(status: status, generation: launchedGeneration) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            ingress.close()
            workingDirectory.remove()
            throw UsageError.codexAppServerUnavailable("Could not start \(executableURL.path): \(error.localizedDescription)")
        }

        self.process = process
        processWorkingDirectory = workingDirectory
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        outputIngress = ingress
        self.executableURL = executableURL
        isReady = false
        jsonl = CodexJSONLBuffer()
    }

    private func sendRequest(
        _ method: CodexJSONRPCMethod,
        params: [String: Any]?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        let id = nextRequestID
        nextRequestID += 1
        let data = try CodexJSONRPC.request(method, id: id, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(continuation: continuation)
            do {
                try write(data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.requestDidTimeOut(id: id, method: method)
            }
        }
    }

    private func write(_ data: Data) throws {
        guard process?.isRunning == true, let inputHandle else {
            throw UsageError.codexAppServerUnavailable("Codex App Server is not running")
        }
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw UsageError.codexAppServerUnavailable("Failed to write to Codex App Server: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data, generation receivedGeneration: Int) {
        guard receivedGeneration == generation else { return }
        let lines: [Data]
        do {
            lines = try jsonl.append(data)
        } catch {
            let usageError = (error as? UsageError) ?? .schemaChanged(error.localizedDescription)
            stopConnection(failingPendingWith: usageError, terminateProcess: true)
            return
        }

        for line in lines {
            switch CodexJSONRPCParser.parse(line) {
            case .result(let id, let payload):
                pending.removeValue(forKey: id)?.continuation.resume(returning: payload)
            case .failure(let id, let code, let message):
                pending.removeValue(forKey: id)?.continuation.resume(
                    throwing: Self.mapRPCError(code: code, message: message)
                )
            case .notification("account/rateLimits/updated", let payload):
                updateContinuation.yield(
                    CodexAppServerRead(payload: payload, serverUserAgent: serverUserAgent)
                )
            case .notification, .ignored:
                // Other notifications are unrelated to this read-only provider. Bad
                // lines are isolated rather than poisoning later JSONL messages.
                continue
            }
        }
    }

    private func drainOutput(_ ingress: CodexOutputIngress, generation receivedGeneration: Int) async {
        while receivedGeneration == generation {
            switch ingress.next() {
            case .chunk(let data):
                receive(data, generation: receivedGeneration)
                // A continuously writing child must not monopolize this actor and
                // prevent stop, timeout, or request operations from running.
                await Task.yield()
            case .overflow:
                stopConnection(
                    failingPendingWith: UsageError.schemaChanged(
                        "Codex App Server queued more than 4 MB of output."
                    ),
                    terminateProcess: true
                )
                return
            case .empty, .closed:
                return
            }
        }
        ingress.close()
    }

    static func mapRPCError(code: Int, message: String) -> UsageError {
        let lower = message.lowercased()
        if code == -32601 || lower.contains("method not found") || lower.contains("not supported") {
            return .codexVersionIncompatible(
                "The selected Codex App Server does not support account/rateLimits/read."
            )
        }
        if lower.contains("not logged in") || lower.contains("not authenticated")
            || lower.contains("authentication required") || lower.contains("login required") {
            return .codexNotLoggedIn
        }
        return .codexAppServerUnavailable("Codex App Server returned error code \(code).")
    }

    private func requestDidTimeOut(id: Int, method: CodexJSONRPCMethod) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: UsageError.codexRequestTimedOut(method.rawValue)
        )
        stopConnection(
            failingPendingWith: UsageError.codexAppServerUnavailable(
                "Codex App Server connection was discarded after a request timeout"
            ),
            terminateProcess: true
        )
    }

    private func processDidExit(status: Int32, generation exitedGeneration: Int) {
        guard exitedGeneration == generation else { return }
        stopConnection(
            failingPendingWith: UsageError.codexAppServerUnavailable(
                "Codex App Server stopped unexpectedly (exit \(status))"
            ),
            terminateProcess: false
        )
    }

    private func stopConnection(failingPendingWith error: UsageError, terminateProcess: Bool) {
        generation += 1
        outputHandle?.readabilityHandler = nil
        outputIngress?.close()
        outputIngress = nil
        try? outputHandle?.close()
        outputHandle = nil
        try? inputHandle?.close()
        inputHandle = nil

        let processToStop = process
        let workingDirectoryToStop = processWorkingDirectory
        process = nil
        processWorkingDirectory = nil
        executableURL = nil
        serverUserAgent = nil
        isReady = false
        jsonl = CodexJSONLBuffer()

        for request in pending.values {
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()

        if terminateProcess, let processToStop {
            beginTermination(of: processToStop, workingDirectory: workingDirectoryToStop)
        } else {
            workingDirectoryToStop?.remove()
        }
    }

    /// Keeps the exact child strongly owned until Foundation observes its exit. A
    /// cooperative App Server normally ends on SIGTERM; a broken one gets one short
    /// grace period before this app hard-stops that same root PID.
    private func beginTermination(
        of process: Process,
        workingDirectory: ProviderProcessWorkingDirectory?
    ) {
        let pid = process.processIdentifier
        terminatingProcesses[pid] = process
        terminatingWorkingDirectories[pid] = workingDirectory
        process.terminationHandler = { [weak self] _ in
            Task { await self?.ownedProcessDidExit(pid: pid) }
        }

        guard process.isRunning else {
            finishOwnedProcess(pid: pid)
            return
        }

        process.terminate()
        let grace = terminationGraceSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            await self?.hardStopTerminatingProcess(pid: pid)
        }
    }

    private func hardStopTerminatingProcess(pid: Int32) {
        guard let process = terminatingProcesses[pid] else { return }
        guard process.isRunning else {
            finishOwnedProcess(pid: pid)
            return
        }
        _ = Darwin.kill(pid, SIGKILL)
    }

    private func ownedProcessDidExit(pid: Int32) {
        finishOwnedProcess(pid: pid)
    }

    private func finishOwnedProcess(pid: Int32) {
        terminatingProcesses.removeValue(forKey: pid)
        terminatingWorkingDirectories.removeValue(forKey: pid)?.remove()
        let waiters = terminationWaiters.removeValue(forKey: pid) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForOwnedProcessToExit(pid: Int32) async {
        guard terminatingProcesses[pid] != nil else { return }
        await withCheckedContinuation { continuation in
            guard terminatingProcesses[pid] != nil else {
                continuation.resume()
                return
            }
            terminationWaiters[pid, default: []].append(continuation)
        }
    }

    private func resumeStartupWaiters(with error: UsageError?) {
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume() }
        }
    }
}
