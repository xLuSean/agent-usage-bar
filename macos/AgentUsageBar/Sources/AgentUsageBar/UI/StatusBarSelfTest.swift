#if DEBUG
import AppKit
import UsageMeterCore

/// Exercises the real `NSStatusItem` wiring and reports what it found.
///
/// Package tests cover the logic but say nothing about whether the menu bar layer was
/// hooked up — the classic "tests pass, UI never changes" gap. This drives the actual
/// `StatusBarController` against the real `NSStatusBar`, then exits.
///
/// It proves items are created, imaged, labelled, and torn down. It does not prove
/// what the user sees on screen; that still needs eyes on a menu bar.
@MainActor
enum StatusBarSelfTest {

    static func run() -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        let defaults = UserDefaults.standard
        // Pin the layout: this suite checks the per-provider items, which do not exist
        // in combined mode. Reading whatever the user last chose made the result depend
        // on their settings rather than on the code.
        let userLayout = SettingsStore.loadLayout(defaults: defaults)
        SettingsStore.saveLayout(.separate, defaults: defaults)
        defer { SettingsStore.saveLayout(userLayout, defaults: defaults) }

        for provider in ProviderKind.allCases {
            SettingsStore.save(
                ProviderSettings(
                    isEnabled: true,
                    identityColor: SettingsStore.defaultColor(for: provider),
                    refreshInterval: .recommended
                ),
                for: provider,
                defaults: defaults
            )
        }

        let model = AppModel()
        var settingsOpened = false
        let controller = StatusBarController(model: model, onOpenSettings: { settingsOpened = true })
        _ = settingsOpened

        let baseline = NSStatusBar.system.thickness
        check(baseline > 0, "NSStatusBar is available (thickness \(baseline))")

        let languageSuite = "AgentUsageBar.selftest.language.\(UUID().uuidString)"
        let languageDefaults = UserDefaults(suiteName: languageSuite)!
        defer { languageDefaults.removePersistentDomain(forName: languageSuite) }
        check(
            SettingsStore.loadLanguage(defaults: languageDefaults) == .traditionalChinese,
            "Display language defaults to Traditional Chinese"
        )
        SettingsStore.saveLanguage(.english, defaults: languageDefaults)
        check(
            SettingsStore.loadLanguage(defaults: languageDefaults) == .english,
            "Display language persists independently from provider settings"
        )

        let historySuite = "AgentUsageBar.selftest.codex-history.\(UUID().uuidString)"
        let historyDefaults = UserDefaults(suiteName: historySuite)!
        defer { historyDefaults.removePersistentDomain(forName: historySuite) }
        check(
            SettingsStore.loadCodexTokenHistoryPeriod(defaults: historyDefaults) == .thirtyDays,
            "Codex token history defaults to 30 days"
        )
        for period in CodexTokenHistoryPeriod.allCases {
            SettingsStore.saveCodexTokenHistoryPeriod(period, defaults: historyDefaults)
            check(
                SettingsStore.loadCodexTokenHistoryPeriod(defaults: historyDefaults) == period,
                "Codex token history persists \(period.rawValue) days"
            )
        }

        let tokenRefreshSuite = "AgentUsageBar.selftest.codex-token-refresh.\(UUID().uuidString)"
        let tokenRefreshDefaults = UserDefaults(suiteName: tokenRefreshSuite)!
        defer { tokenRefreshDefaults.removePersistentDomain(forName: tokenRefreshSuite) }
        check(
            SettingsStore.loadCodexTokenRefreshInterval(defaults: tokenRefreshDefaults) == .oneHour,
            "Codex token refresh defaults to one hour"
        )
        for interval in CodexTokenRefreshInterval.allCases {
            SettingsStore.saveCodexTokenRefreshInterval(interval, defaults: tokenRefreshDefaults)
            check(
                SettingsStore.loadCodexTokenRefreshInterval(defaults: tokenRefreshDefaults) == interval,
                "Codex token refresh persists \(interval.rawValue) seconds"
            )
        }
        historyDefaults.set(11, forKey: "v1.codexTokenHistoryDays")
        check(
            SettingsStore.loadCodexTokenHistoryPeriod(defaults: historyDefaults) == .thirtyDays,
            "Invalid Codex token history preference falls back to 30 days"
        )

        let pauseModel = AppModel(displayLanguage: .traditionalChinese, presenters: [])
        pauseModel.setPaused(true, for: .systemSleep)
        pauseModel.setPaused(true, for: .screenLock)
        pauseModel.setPaused(false, for: .systemSleep)
        check(
            pauseModel.isPollingPaused,
            "Polling stays paused while any independent pause reason remains"
        )
        pauseModel.setPaused(false, for: .screenLock)
        check(
            !pauseModel.isPollingPaused,
            "Polling resumes after every independent pause reason clears"
        )

        let schedulingSuite = "AgentUsageBar.selftest.scheduling.\(UUID().uuidString)"
        let schedulingDefaults = UserDefaults(suiteName: schedulingSuite)!
        defer { schedulingDefaults.removePersistentDomain(forName: schedulingSuite) }
        let pausedPresenter = ProviderPresenter(
            provider: .claude,
            snapshotStore: UsageSnapshotStore(defaults: schedulingDefaults)
        )
        pausedPresenter.startPolling()
        check(pausedPresenter.nextAttemptAt != nil, "Active polling reports its scheduled attempt")
        pausedPresenter.setPaused(true)
        check(pausedPresenter.nextAttemptAt == nil, "Paused polling clears its cancelled attempt")

        let disabledPresenter = ProviderPresenter(
            provider: .claude,
            snapshotStore: UsageSnapshotStore(defaults: schedulingDefaults)
        )
        let originalClaudeSettings = disabledPresenter.settings
        defer { SettingsStore.save(originalClaudeSettings, for: .claude, defaults: defaults) }
        disabledPresenter.startPolling()
        var disabledSettings = disabledPresenter.settings
        disabledSettings.isEnabled = false
        disabledPresenter.settings = disabledSettings
        check(disabledPresenter.nextAttemptAt == nil, "Disabled polling clears its cancelled attempt")

        // A Codex notification can contain only the primary window. It must update that
        // one value without erasing the complete read that the UI and snapshot store
        // already know. This is App-layer coverage: Core tests alone cannot prove the
        // presenter did not reset backoff or postpone the safety poll after merging.
        let sparseSuite = "AgentUsageBar.selftest.codex-sparse.\(UUID().uuidString)"
        let sparseDefaults = UserDefaults(suiteName: sparseSuite)!
        defer { sparseDefaults.removePersistentDomain(forName: sparseSuite) }
        let sparseStore = UsageSnapshotStore(defaults: sparseDefaults)
        let completeFetchedAt = Date()
        let completeSnapshot = UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: 10),
                    resetsAt: completeFetchedAt.addingTimeInterval(3_600),
                    isActive: true,
                    durationMinutes: 300
                ),
                UsageWindow(
                    kind: .weeklyAll,
                    group: .weekly,
                    used: UsedPercent(hundredScale: 60),
                    resetsAt: completeFetchedAt.addingTimeInterval(86_400),
                    isActive: false,
                    durationMinutes: 10_080
                ),
            ],
            fetchedAt: completeFetchedAt,
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "12.50"),
            planType: "plus",
            spendControlReached: false,
            meteredLimitID: "codex",
            sourceVersion: "selftest/complete"
        )
        sparseStore.save(completeSnapshot)
        let sparsePresenter = ProviderPresenter(provider: .codex, snapshotStore: sparseStore)
        var sparseVisualChanges = 0
        sparsePresenter.onVisualChange = { sparseVisualChanges += 1 }
        let nextAttemptBeforePush = sparsePresenter.nextAttemptAt
        let sparseUpdate = UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: [
                UsageWindow(
                    kind: .session,
                    group: .session,
                    used: UsedPercent(hundredScale: 31),
                    resetsAt: completeFetchedAt.addingTimeInterval(4_000),
                    isActive: true,
                    durationMinutes: 300
                )
            ],
            fetchedAt: completeFetchedAt.addingTimeInterval(60),
            meteredLimitID: "codex",
            sourceVersion: "selftest/push"
        )
        sparsePresenter.applyCodexPush(sparseUpdate)
        let mergedSnapshot = sparsePresenter.state.snapshot
        let persistedMergedSnapshot = sparseStore.load(.codex)
        check(
            mergedSnapshot?.windows.first { $0.kind == .session }?.used.usedPercent == 31,
            "Codex sparse push updates the primary window"
        )
        check(
            mergedSnapshot?.windows.first { $0.kind == .weeklyAll } == completeSnapshot.windows[1],
            "Codex sparse push preserves the weekly window"
        )
        check(
            mergedSnapshot?.credits == completeSnapshot.credits
                && mergedSnapshot?.planType == completeSnapshot.planType,
            "Codex sparse push preserves Credits and plan"
        )
        check(
            mergedSnapshot?.fetchedAt == completeFetchedAt,
            "Codex sparse push keeps the last complete-read timestamp"
        )
        check(
            persistedMergedSnapshot == mergedSnapshot,
            "Codex sparse push persists the merged complete snapshot"
        )
        check(
            sparsePresenter.nextAttemptAt == nextAttemptBeforePush,
            "Codex sparse push does not postpone the safety poll"
        )
        check(sparseVisualChanges == 1, "An accepted Codex sparse push redraws exactly once")

        let rejectedUpdate = UsageSnapshot(
            provider: .codex,
            sourcePath: .codexAppServer,
            windows: sparseUpdate.windows,
            fetchedAt: sparseUpdate.fetchedAt,
            meteredLimitID: "codex_other"
        )
        sparsePresenter.applyCodexPush(rejectedUpdate)
        check(
            sparseStore.load(.codex) == persistedMergedSnapshot,
            "An incompatible Codex push does not change persistence"
        )
        check(sparseVisualChanges == 1, "A rejected Codex push does not redraw")

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        SettingsWindowController.configureDesktopBehavior(of: settingsWindow)
        check(
            settingsWindow.collectionBehavior.contains(.moveToActiveSpace),
            "Settings window moves to the current Space when reopened"
        )

        let roomyPopover = StatusBarController.popoverLayout(
            desiredHeight: 620,
            availableHeight: 900
        )
        check(
            roomyPopover == .init(height: 620, usesScrolling: false),
            "Popover expands to fit content without scrolling when the screen has room"
        )
        let constrainedPopover = StatusBarController.popoverLayout(
            desiredHeight: 900,
            availableHeight: 700
        )
        check(
            constrainedPopover == .init(height: 676, usesScrolling: true),
            "Scrolling is enabled only when content exceeds the screen"
        )

        check(model.presenters.count == ProviderKind.allCases.count,
              "Each provider has a presenter (\(model.presenters.count))")
        check(model.allProvidersDisabled == false, "Providers are not all disabled by default")

        for presenter in model.presenters {
            let renderModel = presenter.renderModel
            check(!renderModel.glyph.isEmpty,
                  "\(presenter.provider.displayName) has a non-color identity cue \(renderModel.glyph)")
            check(!renderModel.accessibilityLabel.isEmpty,
                  "\(presenter.provider.displayName) has a VoiceOver label")
            let image = GaugeImageRenderer.image(
                for: renderModel,
                identityColor: presenter.settings.identityColor.nsColor
            )
            check(image.size == GaugeImageRenderer.size,
                  "\(presenter.provider.displayName) gauge rendered (\(image.size.width)×\(image.size.height))")
        }

        // An item that exists but is not visible looks identical to a bug in the gauge
        // drawing, so assert visibility separately from existence.
        for entry in controller.diagnostics {
            let name = entry.provider.displayName
            check(entry.exists, "\(name) NSStatusItem exists")
            check(entry.isVisible, "\(name) NSStatusItem is visible")
            check(entry.hasImage, "\(name) NSStatusItem has an image")
            check(entry.autosaveName != nil, "\(name) has autosaveName (\(entry.autosaveName ?? "nil"))")
        }
        let names = controller.diagnostics.compactMap(\.autosaveName)
        check(Set(names).count == names.count, "Each NSStatusItem has a unique autosaveName")

        // Independent degradation: one provider failing must not disturb the other.
        let claude = model.presenter(for: .claude)!
        let codex = model.presenter(for: .codex)!
        claude.applyDemoScenario(.notLoggedIn)
        codex.applyDemoScenario(.healthy)
        check(claude.renderModel.fillLevel == .unknown, "Claude gauge is unknown when unavailable")
        check(codex.renderModel.fillLevel == .ok, "Codex remains ok when Claude fails")

        // Deadlock guard: turning everything off must leave a way back in.
        for presenter in model.presenters { presenter.settings.isEnabled = false }
        check(model.allProvidersDisabled, "Both disabled state is detected")
        check(model.enabledPresenters.isEmpty, "No providers are enabled")
        controller.synchronize()
        check(GaugeImageRenderer.neutralAppIcon().size.width > 0, "Neutral default app icon renders so the Settings entry point remains")

        for presenter in model.presenters { presenter.settings.isEnabled = true }
        controller.synchronize()
        check(model.allProvidersDisabled == false, "State recovers after re-enabling")

        for provider in ProviderKind.allCases {
            SettingsStore.save(
                ProviderSettings(
                    isEnabled: true,
                    identityColor: SettingsStore.defaultColor(for: provider),
                    refreshInterval: .recommended
                ),
                for: provider,
                defaults: defaults
            )
        }

        // Combined mode replaces the per-provider items with one. Checked here because
        // the two arrangements are different code paths, and the first version of the
        // combined one shipped able to reach only one provider's readings.
        model.menuBarLayout = .combined
        controller.synchronize()
        check(controller.diagnostics.allSatisfy { !$0.exists },
              "Separate NSStatusItems are removed in combined mode")
        check(model.enabledPresenters.count == ProviderKind.allCases.count,
              "Every provider remains readable in combined mode")
        check(
            StatusBarController.providerPlacement(
                isEnabled: true,
                layout: .combined,
                itemPlacement: .onScreen
            ) == .combined,
            "The visible combined item is reported as a combined icon in Settings"
        )
        for provider in ProviderKind.allCases {
            check(controller.placement(for: provider) != .disabled,
                  "\(provider.displayName) is not misreported as disabled in combined mode")
        }
        model.menuBarLayout = .separate
        controller.synchronize()
        check(controller.diagnostics.allSatisfy { $0.exists }, "Separate items return after switching back")

        print(failures.isEmpty ? "\nselftest passed" : "\nselftest FAILED: \(failures.count) items")
        return failures.isEmpty ? 0 : 1
    }

    /// Runs the real fetch path off the main actor, against a stub process.
    ///
    /// Nothing here launches a CLI or opens a socket, but every line between `fetch()`
    /// and a finished snapshot runs on a non-main-actor task. That is where a main-actor
    /// assumption blows up, and nothing else in this suite goes there — the crash it
    /// guards against reached a shipped build.
    ///
    /// It covers the three outcomes that matter: a missing executable, a well-formed
    /// response, and a reading whose window has already rolled over.
    nonisolated static func runLivePathSmoke() async -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures += 1 }
        }

        // 1. A missing executable must fail before anything is spawned.
        let missing = ClaudeUsageProvider(
            locator: ClaudeExecutableLocator(
                configuredPath: "/nonexistent/AgentUsageBar-selftest/claude",
                environment: [:]
            )
        )
        do {
            _ = try await missing.fetch()
            check(false, "A missing executable must not succeed")
        } catch let error as UsageError {
            check(
                error == .claudeExecutableInvalid("/nonexistent/AgentUsageBar-selftest/claude"),
                "A missing executable reports claudeExecutableInvalid (got \(error.shortDescription))"
            )
        } catch {
            check(false, "Unexpected error type \(error)")
        }

        // 2. The whole decode path, off the main actor, against a stub process. This is
        //    the part that used to trap: everything between fetch() and the snapshot runs
        //    on a non-main-actor task.
        let now = Date()
        let resets = now.addingTimeInterval(3_600)
        let fresh = ClaudeUsageProvider(
            locator: ClaudeExecutableLocator(configuredPath: "/bin/echo", environment: [:]),
            runner: StubUsageRunner(output: SelfTestUsageOutput.json(sessionPercent: 42, resetsAt: resets)),
            now: { now }
        )
        do {
            let snapshot = try await fresh.fetch()
            check(snapshot.sourcePath == .claudeCodeCLI, "Snapshot records the CLI source path")
            check(
                snapshot.representativeWindow?.used.usedPercent == 42,
                "Session window decodes to 42% (got \(snapshot.representativeWindow?.used.usedPercent ?? -1))"
            )
        } catch {
            check(false, "A well-formed /usage response must decode (got \(error))")
        }

        // 3. A reading whose window already rolled over must not be shown as current.
        let outdated = ClaudeUsageProvider(
            locator: ClaudeExecutableLocator(configuredPath: "/bin/echo", environment: [:]),
            runner: StubUsageRunner(
                output: SelfTestUsageOutput.json(
                    sessionPercent: 42,
                    resetsAt: now.addingTimeInterval(-3_600)
                )
            ),
            now: { now }
        )
        do {
            _ = try await outdated.fetch()
            check(false, "A reading past its reset time must not be reported as current")
        } catch let error as UsageError {
            guard case .claudeUsageOutdated = error else {
                check(false, "Expected claudeUsageOutdated, got \(error.shortDescription)")
                print(failures == 0 ? "\nlive path smoke passed" : "\nlive path smoke FAILED: \(failures) items")
                return failures == 0 ? 0 : 1
            }
            check(true, "A reading past its reset time reports claudeUsageOutdated")
        } catch {
            check(false, "Unexpected error type \(error)")
        }

        print(failures == 0 ? "\nlive path smoke passed" : "\nlive path smoke FAILED: \(failures) items")
        return failures == 0 ? 0 : 1
    }

    static func runProviderTransitionTests() async -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures += 1 }
        }

        let pathClaudeProvider = TransitionTestProvider()
        let pathCodexProvider = TransitionTestProvider()
        let pathSuite = "AgentUsageBar.selftest.transition-path.\(UUID().uuidString)"
        let pathDefaults = UserDefaults(suiteName: pathSuite)!
        pathDefaults.removePersistentDomain(forName: pathSuite)
        let pathClaudePresenter = ProviderPresenter(
            provider: .claude,
            snapshotStore: UsageSnapshotStore(defaults: pathDefaults),
            providerFactory: { _, _, _ in pathClaudeProvider }
        )
        let pathCodexPresenter = ProviderPresenter(
            provider: .codex,
            snapshotStore: UsageSnapshotStore(defaults: pathDefaults),
            providerFactory: { _, _, _ in pathCodexProvider }
        )
        let pathModel = AppModel(
            displayLanguage: .english,
            presenters: [pathClaudePresenter, pathCodexPresenter]
        )
        pathClaudePresenter.requestRefresh(reason: .manual)
        check(
            await waitForFetchCount(pathClaudeProvider, atLeast: 1),
            "Executable-path test starts the original Claude fetch"
        )
        pathModel.setClaudeExecutablePath("/synthetic/claude-\(UUID().uuidString)")
        await pathClaudeProvider.completeNext(
            with: transitionSnapshot(provider: .claude, sourcePath: .claudeCodeCLI, usedPercent: 88)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(await pathCodexProvider.fetchCount == 0, "Changing Claude's path does not refresh Codex")
        check(
            pathClaudePresenter.state.snapshot?.representativeWindow?.used.usedPercent != 88,
            "A result from the old Claude path is discarded"
        )

        let disableProvider = TransitionTestProvider()
        let disableSuite = "AgentUsageBar.selftest.transition-disable.\(UUID().uuidString)"
        let disableDefaults = UserDefaults(suiteName: disableSuite)!
        disableDefaults.removePersistentDomain(forName: disableSuite)
        let disablePresenter = ProviderPresenter(
            provider: .claude,
            snapshotStore: UsageSnapshotStore(defaults: disableDefaults),
            providerFactory: { _, _, _ in disableProvider }
        )
        disablePresenter.requestRefresh(reason: .manual)
        check(
            await waitForFetchCount(disableProvider, atLeast: 1),
            "Disable test starts the original fetch"
        )
        disablePresenter.settings.isEnabled = false
        await disableProvider.completeNext(
            with: transitionSnapshot(provider: .claude, sourcePath: .claudeCodeCLI, usedPercent: 73)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(
            disablePresenter.state.snapshot?.representativeWindow?.used.usedPercent != 73,
            "A result arriving after disable is discarded"
        )

        let shutdownProvider = ShutdownTestProvider()
        let shutdownSuite = "AgentUsageBar.selftest.transition-shutdown.\(UUID().uuidString)"
        let shutdownDefaults = UserDefaults(suiteName: shutdownSuite)!
        shutdownDefaults.removePersistentDomain(forName: shutdownSuite)
        let shutdownPresenter = ProviderPresenter(
            provider: .claude,
            snapshotStore: UsageSnapshotStore(defaults: shutdownDefaults),
            providerFactory: { _, _, _ in shutdownProvider }
        )
        // The preceding disable scenario intentionally persists Claude as disabled in
        // this isolated diagnostic domain. Re-enable it before exercising shutdown.
        shutdownPresenter.settings.isEnabled = true
        let shutdownModel = AppModel(
            displayLanguage: .english,
            presenters: [shutdownPresenter]
        )
        shutdownModel.refreshAll()
        check(
            await waitForFetchCount(shutdownProvider, atLeast: 1),
            "App shutdown test starts an owned provider fetch"
        )
        await shutdownModel.stop()
        check(
            await shutdownProvider.cancellationObserved,
            "App shutdown cancels and awaits the owned provider fetch"
        )

        for suite in [pathSuite, disableSuite, shutdownSuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        print(failures == 0 ? "\nprovider transition selftest passed" : "\nprovider transition selftest FAILED: \(failures) items")
        return failures == 0 ? 0 : 1
    }
}

private actor TransitionTestProvider: UsageProvider {
    private var queued: [UsageSnapshot] = []
    private var pending: [CheckedContinuation<UsageSnapshot, any Error>] = []
    private(set) var fetchCount = 0

    func fetch() async throws -> UsageSnapshot {
        fetchCount += 1
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    func completeNext(with snapshot: UsageSnapshot) {
        guard !pending.isEmpty else {
            queued.append(snapshot)
            return
        }
        pending.removeFirst().resume(returning: snapshot)
    }
}

private actor ShutdownTestProvider: UsageProvider {
    private(set) var fetchCount = 0
    private(set) var cancellationObserved = false

    func fetch() async throws -> UsageSnapshot {
        fetchCount += 1
        do {
            while true {
                try await Task.sleep(for: .seconds(60))
            }
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }
}

private func waitForFetchCount(
    _ provider: TransitionTestProvider,
    atLeast expected: Int
) async -> Bool {
    for _ in 0..<100 {
        if await provider.fetchCount >= expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func waitForFetchCount(
    _ provider: ShutdownTestProvider,
    atLeast expected: Int
) async -> Bool {
    for _ in 0..<100 {
        if await provider.fetchCount >= expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func transitionSnapshot(
    provider: ProviderKind,
    sourcePath: UsageSourcePath,
    usedPercent: Double
) -> UsageSnapshot {
    UsageSnapshot(
        provider: provider,
        sourcePath: sourcePath,
        windows: [
            UsageWindow(
                kind: .session,
                group: .session,
                used: UsedPercent(hundredScale: usedPercent),
                resetsAt: Date().addingTimeInterval(3_600),
                isActive: true,
                durationMinutes: 300
            )
        ],
        fetchedAt: Date()
    )
}

/// Stands in for the real process so the smoke test never launches a CLI.
private struct StubUsageRunner: ClaudeCommandRunning {
    let output: ClaudeCommandOutput

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ClaudeCommandOutput {
        output
    }
}

/// Builds a `/usage` envelope with neutral content. No real percentages, no session id,
/// and none of the local-activity breakdown the real command also prints.
private enum SelfTestUsageOutput {
    static func json(sessionPercent: Int, resetsAt: Date) -> ClaudeCommandOutput {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d 'at' h:mma"
        let stamp = formatter.string(from: resetsAt)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
        let zone = TimeZone.current.identifier

        let result = """
        You are currently using your subscription to power your Claude Code usage

        Current session: \(sessionPercent)% used · resets \(stamp) (\(zone))
        Current week (all models): 7% used · resets \(stamp) (\(zone))
        """
        let envelope: [String: Any] = [
            "is_error": false,
            "subtype": "success",
            "result": result,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return ClaudeCommandOutput(exitCode: 0, standardOutput: data)
    }
}
#endif
