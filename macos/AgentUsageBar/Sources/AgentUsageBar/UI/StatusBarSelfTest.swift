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
        check(claude.renderModel.session.fillLevel == .unknown && claude.renderModel.weekly.fillLevel == .unknown,
              "Both Claude slots are unknown when unavailable")
        check(codex.renderModel.session.fillLevel == .ok, "Codex remains ok when Claude fails")

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

        // Crossing a low-quota boundary must never widen the shared-frame icon.
        for layout in [MenuBarLayout.separate, .combined] {
            model.menuBarLayout = layout
            claude.applyDemoScenario(.healthy)
            codex.applyDemoScenario(.lowSession)
            func checkImageLayout(_ widths: [CGFloat], _ description: String) {
                let actual = controller.imageLayoutDiagnostics
                check(actual.compactMap(\.imageSize?.width) == widths,
                      "\(description): rendered widths match")
                check(actual.allSatisfy { entry in
                    guard let size = entry.imageSize else { return false }
                    return size.height == 18 && entry.length == size.width + 8
                }, "\(description): AppKit allocates the complete image plus padding")
            }
            checkImageLayout(layout == .separate ? [27, 27] : [57], "Mixed low-quota layout")
            claude.applyDemoScenario(.lowWeekly)
            codex.applyDemoScenario(.bothLow)
            checkImageLayout(layout == .separate ? [27, 27] : [57], "Weekly and both-window percentages preserve fixed width")
            check(claude.renderModel.session.lowRemainingPercent == nil && claude.renderModel.weekly.lowRemainingPercent == 9,
                  "Only the low weekly half switches to a percentage")
            check(codex.renderModel.session.lowRemainingPercent == 1 && codex.renderModel.weekly.lowRemainingPercent == 10,
                  "Both low windows show their own remaining percentages, including 10%")
            claude.applyDemoScenario(.lastPercent)
            codex.applyDemoScenario(.exhausted)
            checkImageLayout(layout == .separate ? [27, 27] : [57], "Both low, including exhausted quota")
            check(codex.renderModel.session.lowRemainingPercent == 0 && codex.renderModel.weekly.lowRemainingPercent == 0,
                  "Exhausted current windows show 0% remaining")
            claude.applyDemoScenario(.lowQuotaBoundary)
            codex.applyDemoScenario(.lowQuotaBoundary)
            checkImageLayout(layout == .separate ? [27, 27] : [57], "Quota recovery preserves fixed width")
            claude.applyDemoScenario(.healthy)
            codex.applyDemoScenario(.healthy)
            checkImageLayout(layout == .separate ? [27, 27] : [57], "Healthy bars return without changing width")
            claude.applyDemoScenario(.missingSession)
            codex.applyDemoScenario(.missingWeekly)
            checkImageLayout(layout == .separate ? [27, 27] : [57], "Missing quota preserves both fixed slots")
            check(claude.renderModel.session.availability == .notListed
                  && claude.renderModel.weekly.availability == .reported,
                  "An omitted Claude session preserves its real weekly reading")
            check(codex.renderModel.session.availability == .reported
                  && codex.renderModel.weekly.availability == .unknown,
                  "A missing Codex weekly meter cannot erase its session reading")
        }

        // Folding a row changes the panel's height after the popover has been sized.
        // The popover has to follow, in both layouts, or the panel is clipped or left
        // with a gap under the buttons. A render check cannot see this: it measures a
        // view, not a popover.
        //
        // The screen height is supplied rather than read. On a short display the
        // popover is already clamped to the screen and a fold cannot shrink it, so a
        // check written against whatever display this runs on passes on one machine
        // and fails on another for reasons that have nothing to do with the wiring.
        for layout in [MenuBarLayout.separate, .combined] {
            model.menuBarLayout = layout
            claude.applyDemoScenario(.healthy)
            codex.applyDemoScenario(.healthy)
            guard let session = claude.state.snapshot?.windows.first(where: { $0.kind == .session }) else {
                check(false, "\(layout.rawValue): the healthy scenario has no session row to fold")
                continue
            }
            for (screen, available) in [("roomy screen", CGFloat(4_000)), ("short screen", CGFloat(300))] {
                let label = "\(layout.rawValue), \(screen)"
                guard let heights = controller.foldResizeDiagnostics(
                    folding: session, of: .claude, availableHeight: available
                ) else {
                    check(false, "\(label): could not build a popover to fold a row in")
                    continue
                }
                check(
                    heights.folded == heights.openedFolded,
                    "\(label): after a fold the popover is the size it would open at (\(Int(heights.folded)) pt)"
                )
                check(
                    heights.unfolded == heights.opened,
                    "\(label): unfolding restores the height (\(Int(heights.unfolded)) pt)"
                )
                if available > 1_000 {
                    check(
                        heights.folded < heights.opened,
                        "\(label): folding a row shrinks the popover (\(Int(heights.opened)) → \(Int(heights.folded)) pt)"
                    )
                } else {
                    let limit = StatusBarController.popoverLayout(
                        desiredHeight: 10_000, availableHeight: available
                    ).height
                    check(
                        heights.opened <= limit && heights.folded <= heights.opened,
                        "\(label): the popover never outgrows the screen (\(Int(heights.opened)) → \(Int(heights.folded)) pt, limit \(Int(limit)) pt)"
                    )
                }
            }
        }
        check(
            model.windowDisclosure.disclosure == WindowDisclosure(),
            "The fold check leaves no row folded behind it"
        )

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

        // 4. The shape the fixed command actually prints: the array, with the structured
        //    report attached. The rows win over the prose beside them, which reads 42%.
        let reported = ClaudeUsageProvider(
            locator: ClaudeExecutableLocator(configuredPath: "/bin/echo", environment: [:]),
            runner: StubUsageRunner(
                output: SelfTestUsageOutput.verbose(
                    prose: SelfTestUsageOutput.json(sessionPercent: 42, resetsAt: resets),
                    rows: SelfTestUsageOutput.rows(sessionPercent: 17, resetsAt: resets)
                )
            ),
            now: { now }
        )
        do {
            let snapshot = try await reported.fetch()
            check(
                snapshot.representativeWindow?.used.usedPercent == 17,
                "Report rows are read in preference to the prose (got \(snapshot.representativeWindow?.used.usedPercent ?? -1))"
            )
            check(
                snapshot.windows.contains { $0.kind == .weeklyScoped && $0.modelDisplayName == "Example Model" },
                "A per-model weekly row decodes with its label"
            )
            check(
                snapshot.windows.first { $0.kind == .weeklyAll }?.isActive == true,
                "The row the server marks as binding is marked as binding"
            )
        } catch {
            check(false, "A well-formed usage report must decode (got \(error))")
        }

        // 5. Claude Code ran but had no figure from the server. The prose still prints
        //    42%, and that is exactly what must not be shown.
        let unavailable = ClaudeUsageProvider(
            locator: ClaudeExecutableLocator(configuredPath: "/bin/echo", environment: [:]),
            runner: StubUsageRunner(
                output: SelfTestUsageOutput.verbose(
                    prose: SelfTestUsageOutput.json(sessionPercent: 42, resetsAt: resets),
                    rows: nil
                )
            ),
            now: { now }
        )
        do {
            _ = try await unavailable.fetch()
            check(false, "A report with no rows must not fall back to the prose")
        } catch let error as UsageError {
            check(
                error == .claudeUsageUnavailable,
                "A report with no rows reports claudeUsageUnavailable (got \(error.shortDescription))"
            )
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
        await checkCodexDiagnosticHistory(check)
        print(failures == 0 ? "\nprovider transition selftest passed" : "\nprovider transition selftest FAILED: \(failures) items")
        return failures == 0 ? 0 : 1
    }

    private static func checkCodexDiagnosticHistory(_ check: (Bool, String) -> Void) async {
        guard let fixture = ProcessInfo.processInfo.environment["AUB_CODEX_DIAGNOSTIC_FIXTURE"],
              FileManager.default.isExecutableFile(atPath: fixture) else {
            check(false, "Codex diagnostic test requires its executable fixture")
            return
        }
        let suite = "AgentUsageBar.selftest.codex-errors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            unsetenv("AUB_CODEX_STUB_RECOVERED")
            defaults.removePersistentDomain(forName: suite)
        }
        let english = Locale(identifier: "en_US")
        for recovered in [false, true] {
            setenv("AUB_CODEX_STUB_RECOVERED", recovered ? "1" : "0", 1)
            let store = DiagnosticLogStore(defaults: defaults)
            let presenter = ProviderPresenter(provider: .codex, snapshotStore: .init(defaults: defaults))
            let model = AppModel(presenters: [presenter], diagnosticLogStore: store)
            presenter.codexExecutablePath = { fixture }
            presenter.settings.isEnabled = true
            model.refreshAll()
            let deadline = Date().addingTimeInterval(5)
            var reports: [String] = []
            repeat {
                try? await Task.sleep(for: .milliseconds(20))
                reports = model.diagnosticEntries.map { $0.copyText(locale: english) }
            } while Date() < deadline && (reports.count != 2 || (recovered &&
                !reports.allSatisfy { $0.contains("using a different background process") }))

            check(reports.count == 2 && reports.contains { $0.contains("account/rateLimits/read") && $0.contains("HTTP 401") } &&
                  reports.contains { $0.contains("account/usage/read") && $0.contains("no recognized cause") },
                  "Settings receives each query's own sanitized failure")
            if recovered {
                check(reports.count == 2 && reports.allSatisfy { $0.contains("using a different background process") },
                      "Successful reads after rebuilding the app model annotate both failures")
                check(presenter.state.snapshot?.codexAccountUsage?.lifetimeTokens == 34,
                      "The recovered token reading reaches the quota snapshot")
            }
            check(store.load() == model.diagnosticEntries, "The displayed diagnostics match persisted history")
            if recovered {
                do {
                    let reading = try await CodexUsageProvider(configuredExecutablePath: fixture)
                        .quotaReading(preserving: nil)
                    if let query = reading.query {
                        let afterRetention = Date().addingTimeInterval(6 * 86_400)
                        model.recordCodexSuccess(query, now: afterRetention)
                        check(store.load(now: afterRetention).isEmpty && model.diagnosticEntries.isEmpty,
                              "Expired rows disappear from Settings on success without a new recovery")
                    } else { check(false, "The synthetic read supplies its query context") }
                } catch { check(false, "The isolated quota query succeeds for the retention check") }
            }
            await model.stop()
        }
        unsetenv("AUB_CODEX_STUB_RECOVERED")
        await checkCodexTimers(fixture: fixture, check: check)
        await checkCodexSourceChange(fixture: fixture, check: check)
    }

    private static func waitUntil(_ ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !ready() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return ready()
    }

    private static func checkCodexTimers(fixture: String, check: (Bool, String) -> Void) async {
        let suite = "AgentUsageBar.selftest.codex-timers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageSnapshotStore(defaults: defaults)
        let previous = transitionSnapshot(provider: .codex, sourcePath: .codexAppServer, usedPercent: 9)
        store.save(previous)
        var now = previous.fetchedAt.addingTimeInterval(60)
        var timers: [(delay: TimeInterval, timer: Timer)] = []
        let presenter = ProviderPresenter(provider: .codex, snapshotStore: store, now: { now }, scheduleTimer: { delay, action in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            timers.append((delay, timer))
            return timer
        })
        let model = AppModel(presenters: [presenter], diagnosticLogStore: .init(defaults: defaults))
        presenter.codexExecutablePath = { fixture }
        presenter.settings.refreshInterval = .tenMinutes
        presenter.codexTokenRefreshInterval = .oneHour
        presenter.settings.isEnabled = true
        presenter.requestRefresh(reason: .manual)
        func tokenFailures() -> Int {
            model.diagnosticEntries.filter { $0.copyText(locale: Locale(identifier: "en_US")).contains("account/usage/read") }.count
        }
        let started = await waitUntil { presenter.consecutiveFailures == 1 && tokenFailures() == 1 }
        guard started, let quotaTimer = timers.last(where: { $0.delay == 60 && $0.timer.isValid })?.timer,
              let tokenTimer = timers.last(where: { $0.delay == 3_600 && $0.timer.isValid })?.timer else {
            check(false, "Both failed reads schedule their respective timers")
            await model.stop()
            return
        }
        now.addTimeInterval(60)
        quotaTimer.fire()
        check(await waitUntil { presenter.consecutiveFailures == 2 },
              "The one-minute quota retry actually reads despite a fresh cached snapshot")
        check(tokenFailures() == 1 && tokenTimer.isValid,
              "A quota retry leaves the failed token read and its hourly timer alone")

        presenter.settings.refreshInterval = .thirtyMinutes
        check(presenter.nextAttemptAt == now.addingTimeInterval(120),
              "Changing the regular quota interval keeps the pending retry deadline")
        presenter.setPaused(true)
        presenter.setPaused(false)
        let resumed = await waitUntil { timers.contains { $0.delay == 3_540 && $0.timer.isValid } }
        check(resumed && tokenFailures() == 1, "Resuming preserves the remaining token interval after failure")
        now.addTimeInterval(3_540)
        timers.last(where: { $0.delay == 3_540 && $0.timer.isValid })?.timer.fire()
        check(await waitUntil { tokenFailures() == 2 }, "The independent token timer retries when its hour is due")
        await model.stop()
    }

    private static func checkCodexSourceChange(fixture: String, check: (Bool, String) -> Void) async {
        let suite = "AgentUsageBar.selftest.codex-source.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        setenv("AUB_CODEX_STUB_QUOTA_ONLY", "1", 1)
        defer {
            unsetenv("AUB_CODEX_STUB_QUOTA_ONLY")
            defaults.removePersistentDomain(forName: suite)
        }
        SettingsStore.saveCodexExecutablePath("/synthetic/previous-codex")
        let store = UsageSnapshotStore(defaults: defaults)
        let old = transitionSnapshot(provider: .codex, sourcePath: .codexAppServer, usedPercent: 99)
            .replacingCodexAccountUsage(.init(lifetimeTokens: 34_567, peakDailyTokens: nil, dailyUsageBuckets: [], fetchedAt: Date()))
        store.save(old)
        let presenter = ProviderPresenter(provider: .codex, snapshotStore: store)
        let model = AppModel(presenters: [presenter], diagnosticLogStore: .init(defaults: defaults))
        check(presenter.state.snapshot?.codexAccountUsage?.lifetimeTokens == 34_567, "The previous source has stored token usage")
        model.setCodexExecutablePath(fixture)
        check(presenter.state.snapshot == nil && store.load(.codex) == nil,
              "Changing Codex source immediately removes the previous reading from the screen and storage")
        let finished = await waitUntil {
            presenter.state.snapshot?.representativeWindow?.used.usedPercent == 12 && !model.diagnosticEntries.isEmpty
        }
        check(finished && presenter.state.snapshot?.codexAccountUsage == nil && store.load(.codex)?.codexAccountUsage == nil,
              "Successful quota and failed token reads on the new source cannot inherit the old source's tokens")
        await model.stop()
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

    /// Synthetic report rows: the two required meters and one per-model weekly limit.
    static func rows(sessionPercent: Int, resetsAt: Date) -> [[String: Any]] {
        let stamp = ISO8601DateFormatter().string(from: resetsAt)
        return [
            ["kind": "session", "group": "session", "percent": sessionPercent,
             "resets_at": stamp, "is_active": false],
            ["kind": "weekly_all", "group": "weekly", "percent": 7,
             "resets_at": stamp, "is_active": true],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 3,
             "resets_at": stamp, "is_active": false,
             "scope": ["model": ["display_name": "Example Model"]]],
        ]
    }

    /// The array the fixed command prints with `--verbose`. `rows == nil` is a report
    /// with no figure from the server.
    static func verbose(prose: ClaudeCommandOutput, rows: [[String: Any]]?) -> ClaudeCommandOutput {
        let result = (try? JSONSerialization.jsonObject(with: prose.standardOutput)) as? [String: Any] ?? [:]
        let limits: Any = rows.map { $0 as Any } ?? NSNull()
        let messages: [[String: Any]] = [
            ["type": "system", "subtype": "init"],
            ["type": "assistant", "usage_report": ["rate_limits": ["limits": limits]]],
            result.merging(["type": "result"]) { _, new in new },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: messages)) ?? Data()
        return ClaudeCommandOutput(exitCode: 0, standardOutput: data)
    }
}
#endif
