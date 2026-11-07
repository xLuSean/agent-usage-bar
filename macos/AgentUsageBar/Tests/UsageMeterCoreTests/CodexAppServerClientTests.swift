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

        let generic = CodexRPCRejection(code: -32000, message: privateUpstreamText).usageError(for: .rateLimitsRead)
        #expect(generic.remedy?.contains(privateUpstreamText) == false)
        #expect(generic.remedy?.contains("/Users/private") == false)

        let unsupported = CodexRPCRejection(
            code: -32601,
            message: "method not found; \(privateUpstreamText)"
        ).usageError(for: .accountUsageRead)
        #expect(unsupported.remedy?.contains(privateUpstreamText) == false)
        #expect(unsupported.remedy?.contains("/Users/private") == false)
        #expect(unsupported.remedy?.contains("account/usage/read") == true)
    }

    @Test("failed quota and token requests retain their own process and reason through storage")
    func recordsFailuresAcrossReconnect() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-error-stub")
        let client = CodexAppServerClient(initializeTimeoutSeconds: 2, readTimeoutSeconds: 2)
        let provider = CodexUsageProvider(configuredExecutablePath: fixture.path, client: client)
        func failure(quota: Bool) async throws -> CodexQueryFailure {
            do {
                if quota { _ = try await provider.quotaReading(preserving: nil) }
                else { _ = try await provider.tokenReading(fetchedAt: Date()) }
            } catch let error as CodexQueryFailure { return error }
            throw TestFailure.missingError
        }

        do {
            let first = try await failure(quota: true)
            #expect(first.diagnostic.method == .rateLimitsRead)
            #expect(first.diagnostic.process?.reused == false)
            #expect(first.diagnostic.rpc?.httpStatus == 401)
            #expect(first.diagnostic.rpc?.reason == .tokenExpired)
            async let quota = failure(quota: true)
            async let tokens = failure(quota: false)
            let (repeated, optional) = try await (quota, tokens)
            for query in [repeated.diagnostic, optional.diagnostic] {
                #expect(query.process?.startedAt == first.diagnostic.process?.startedAt)
                #expect(query.process?.reused == true)
                #expect(query.rpc?.code == -32603)
            }
            #expect(repeated.diagnostic.rpc?.reason == .tokenExpired)
            #expect(optional.diagnostic.method == .accountUsageRead)
            #expect(optional.diagnostic.rpc?.reason == .unspecified)
            #expect(optional.diagnostic.rpc?.httpStatus == nil)

            let suite = "io.github.sean.AgentUsageBar.tests.rpc.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = DiagnosticLogStore(defaults: defaults)
            for item in [first, optional] {
                _ = store.append(provider: .codex, error: item.error, codexQuery: item.diagnostic)
            }
            let loaded = store.load()
            #expect(loaded.map(\.codexQuery) == [optional.diagnostic, first.diagnostic])
            let en = Locale(identifier: "en_US"), zh = Locale(identifier: "zh_Hant_TW")
            #expect(loaded[0].copyText(locale: en).contains("no recognized cause"))
            #expect(loaded[0].detailMessage(locale: zh).contains("沿用"))
            #expect(loaded[1].detailMessage(locale: zh).contains("登入憑證已過期"))
            for locale in [en, zh] {
                let report = loaded[1].copyText(locale: locale)
                #expect(report.contains("HTTP 401") && report.contains("-32603"))
                #expect(report.contains("token_expired"))
                #expect(report.contains("account/rateLimits/read"))
                #expect(!report.contains("private-marker"))
            }
            let bytes = try #require(defaults.data(forKey: "v1.diagnosticLog"))
            #expect(!String(decoding: bytes, as: UTF8.self).contains("private-marker"))

            await client.stop()
            let restarted = try await failure(quota: true)
            #expect(restarted.diagnostic.process?.reused == false)
            #expect(restarted.diagnostic.process?.startedAt != first.diagnostic.process?.startedAt)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private enum TestFailure: Error { case missingError }

    @Test("a queued rate-limit notification is accepted only for its originating executable")
    func notificationRetainsSource() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let fixture = fixtures.appendingPathComponent("codex-app-server-error-stub").path
        let other = fixtures.appendingPathComponent("codex-app-server-timeout-stub").path
        setenv("AUB_CODEX_STUB_QUOTA_ONLY", "1", 1)
        defer { unsetenv("AUB_CODEX_STUB_QUOTA_ONLY") }
        let client = CodexAppServerClient(initializeTimeoutSeconds: 2, readTimeoutSeconds: 2)
        do {
            _ = try await client.readRateLimits(configuredExecutablePath: fixture)
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
        let queued = Task {
            var updates = client.rateLimitUpdates.makeAsyncIterator()
            return await updates.next()
        }
        let deadline = Task { try await Task.sleep(for: .seconds(2)); queued.cancel() }
        defer { deadline.cancel() }
        let update = try #require(await queued.value)
        #expect(update.isNotification(fromConfiguredPath: fixture))
        #expect(!update.isNotification(fromConfiguredPath: other))
    }

    @Test("a child exiting during initialization preserves its exit status on the intended read")
    func initializationExitRetainsStatus() async {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-error-stub").path
        setenv("AUB_CODEX_STUB_EXIT_ON_INIT", "1", 1)
        defer { unsetenv("AUB_CODEX_STUB_EXIT_ON_INIT") }
        let client = CodexAppServerClient(initializeTimeoutSeconds: 2, readTimeoutSeconds: 2)
        do {
            _ = try await client.readWithDiagnostics(.tokenUsage, configuredExecutablePath: fixture)
            Issue.record("The fixture exited before it could initialize")
        } catch let failure as CodexQueryFailure {
            #expect(failure.diagnostic.method == .accountUsageRead)
            #expect(failure.diagnostic.failedDuringInitialization == true)
            #expect(failure.diagnostic.processExit?.status == 78)
            #expect(failure.diagnostic.processExit?.signalled == false)
        } catch { Issue.record("Unexpected initialization error: \(error)") }
        await client.stop()
    }

    @Test("a delayed exit notice and an old read deadline cannot stop the replacement")
    func deadProcessWithPendingRead() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-error-stub")
        let first = Process()
        let timeout: TimeInterval = 2
        let client = CodexAppServerClient(initializeTimeoutSeconds: 2, readTimeoutSeconds: timeout,
                                         makeProcess: { first.executableURL == nil ? first : Process() })
        setenv("AUB_CODEX_STUB_RECOVERED", "1", 1)
        setenv("AUB_CODEX_STUB_EXIT_ON_QUOTA", "1", 1)
        defer {
            unsetenv("AUB_CODEX_STUB_EXIT_ON_QUOTA")
            unsetenv("AUB_CODEX_STUB_RECOVERED")
        }
        do {
            _ = try await client.readWithDiagnostics(.tokenUsage, configuredExecutablePath: fixture.path)
            let directory = try #require(first.currentDirectoryURL)
            let deliverExit = try #require(first.terminationHandler)
            first.terminationHandler = { _ in } // deliver the actual notice after reconnection
            unsetenv("AUB_CODEX_STUB_EXIT_ON_QUOTA") // only the first child exits on this read
            let pending = Task { try await client.readWithDiagnostics(.quota, configuredExecutablePath: fixture.path) }
            let clock = ContinuousClock()
            let exitDeadline = clock.now.advanced(by: .seconds(timeout))
            while first.isRunning && clock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(!first.isRunning && first.terminationStatus == 79)
            let afterOldDeadline = clock.now.advanced(by: .seconds(timeout))
            let replacement = try await client.readWithDiagnostics(.quota, configuredExecutablePath: fixture.path)
            let replacementID = try #require(replacement.diagnostic?.process?.id)
            deliverExit(first)
            do {
                _ = try await pending.value
                Issue.record("The exited child cannot have returned a quota result")
            } catch let failure as CodexQueryFailure {
                #expect(failure.error == .codexAppServerUnavailable("Codex App Server stopped unexpectedly (exit 79)"))
                let entry = DiagnosticLogEntry(
                    occurredAt: Date(), provider: .codex, kind: .init(failure.error),
                    detail: .init(provider: .codex, error: failure.error), codexQuery: failure.diagnostic
                )
                let saved = try JSONDecoder().decode(DiagnosticLogEntry.self, from: JSONEncoder().encode(entry))
                #expect(saved.detailMessage(locale: Locale(identifier: "zh_Hant_TW")).contains("退出碼 79"))
                #expect(saved.copyText(locale: Locale(identifier: "en_US")).contains("exit code 79"))
            }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            try await clock.sleep(until: afterOldDeadline)
            let next = try await client.readWithDiagnostics(.tokenUsage, configuredExecutablePath: fixture.path)
            #expect(next.diagnostic?.process?.id == replacementID)
            #expect(next.diagnostic?.process?.reused == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test("a shared handshake rejection is attributable to each intended query")
    func initializationFailureKeepsQuery() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-app-server-error-stub")
        let client = CodexAppServerClient()
        #expect(setenv("AUB_CODEX_STUB_INIT_FAILURE", "1", 1) == 0)
        defer { unsetenv("AUB_CODEX_STUB_INIT_FAILURE") }
        func failedHandshake(_ query: CodexUsageQuery) async -> CodexQueryDiagnostic? {
            do { _ = try await client.readWithDiagnostics(query, configuredExecutablePath: fixture.path) }
            catch let failure as CodexQueryFailure { return failure.diagnostic }
            catch { Issue.record("Unexpected handshake error: \(error)") }
            return nil
        }
        async let quotaRequest = failedHandshake(.quota)
        async let tokenRequest = failedHandshake(.tokenUsage)
        let (quota, tokens) = await (quotaRequest, tokenRequest)
        await client.stop()
        #expect(quota?.method == .rateLimitsRead)
        #expect(tokens?.method == .accountUsageRead)
        for query in [quota, tokens] {
            #expect(query?.failedDuringInitialization == true)
            #expect(query?.rpc?.code == -32603)
            #expect(query?.process?.reused == false)
        }
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
            #expect(snapshot.codexAccountUsage?.lifetimeTokens == 1_234)
            #expect(snapshot.codexAccountUsage?.updatedThrough == "2026-08-31")

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
