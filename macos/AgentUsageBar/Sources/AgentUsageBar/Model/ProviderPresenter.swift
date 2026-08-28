import AppKit
import Observation
import UsageMeterCore

/// Owns one provider's state. One instance per provider, each with its own backoff
/// counters — Claude's ceiling has to exceed its penalty window and Codex's does not,
/// so a shared instance would force one of them to be wrong.
@MainActor
@Observable
final class ProviderPresenter {

    typealias ProviderFactory = @MainActor (
        _ provider: ProviderKind,
        _ claudeExecutablePath: String?,
        _ codexExecutablePath: String?
    ) -> any UsageProvider

    let provider: ProviderKind
    private(set) var state: UsageDisplayState = .starting

    var settings: ProviderSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings, for: provider)
            let enabledChanged = settings.isEnabled != oldValue.isEnabled
            if settings.refreshInterval != oldValue.refreshInterval || enabledChanged {
                rescheduleTimer()
            }
            if enabledChanged {
                let generation = advanceConfigurationGeneration()
                if settings.isEnabled {
                    requestRefresh(reason: .manual)
                } else {
                    pendingRefreshReason = nil
                    if provider == .codex {
                        Task { [weak self] in
                            guard let self, self.isCurrentConfiguration(generation) else { return }
                            await CodexAppServerClient.shared.stop()
                        }
                    }
                }
            }
            onVisualChange?()
        }
    }

    private(set) var lastAttemptAt: Date?
    private(set) var nextAttemptAt: Date?
    private(set) var consecutiveFailures = 0

    private var backoff: RetryBackoff
    private var isFetching = false
    private var isShuttingDown = false
    private var configurationGeneration: UInt64 = 0
    private var refreshTaskGeneration: UInt64 = 0
    private var pendingRefreshReason: FetchPacing.Reason?
    private var refreshTask: Task<Void, Never>?
    private let snapshotStore: UsageSnapshotStore
    private let providerFactory: ProviderFactory?
    private var timer: Timer?
    /// Set while the screen is locked or the machine is asleep. Polling an endpoint that
    /// rate limits per token while nobody is looking spends the budget for nothing.
    private var isPaused = false
    private var codexUpdatesTask: Task<Void, Never>?

    /// Called when anything that affects the drawn icon changes.
    var onVisualChange: (() -> Void)?

    /// Supplied by AppModel. Only accepted fetch failures reach this callback; malformed
    /// advisory pushes remain ignored and cannot flood the persisted diagnostic log.
    var onDiagnosticError: ((UsageError) -> Void)?

    /// Supplied by AppModel. `nil` means auto-detect common executable locations.
    var claudeExecutablePath: () -> String? = { nil }

    /// Supplied by AppModel. `nil` means auto-detect common executable locations.
    var codexExecutablePath: () -> String? = { nil }

    convenience init(provider: ProviderKind) {
        self.init(provider: provider, snapshotStore: UsageSnapshotStore())
    }

    init(
        provider: ProviderKind,
        snapshotStore: UsageSnapshotStore,
        providerFactory: ProviderFactory? = nil
    ) {
        self.provider = provider
        self.settings = SettingsStore.load(provider)
        self.backoff = RetryBackoff(policy: .forProvider(provider))
        self.snapshotStore = snapshotStore
        self.providerFactory = providerFactory

        // Start from what was already known rather than from nothing. A relaunch used
        // to blank the gauge and immediately ask again; the reading it threw away was
        // usually still good.
        if let stored = snapshotStore.load(provider) {
            let age = Date().timeIntervalSince(stored.fetchedAt)
            state = age < settings.refreshInterval.seconds
                ? .current(stored)
                : .stale(stored, reason: .transport("Data is from the previous app session"))
        }
    }

    #if DEBUG
    /// Diagnostic-only state injection. Release does not compile `DemoScenario` or any
    /// fixture/live branch into the presenter.
    func applyDemoScenario(_ scenario: DemoScenario) {
        state = scenario.state()
        backoff.reset()
        consecutiveFailures = 0
        cancelScheduledAttempt()
        onVisualChange?()
    }
    #endif

    // MARK: - Polling

    /// Claude has no push channel, so polling is structural rather than a preference.
    /// Each provider runs its own timer from its saved RefreshInterval and keeps its
    /// own backoff state for failed fetches.
    func startPolling() {
        subscribeToCodexUpdatesIfNeeded()
        rescheduleTimer()
    }

    private func subscribeToCodexUpdatesIfNeeded() {
        guard provider == .codex, codexUpdatesTask == nil else { return }
        let updates = CodexAppServerClient.shared.rateLimitUpdates
        codexUpdatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { return }
                guard self.settings.isEnabled, !self.isPaused else { continue }
                do {
                    let snapshot = try CodexRateLimitDecoder.decode(
                        update.payload,
                        fetchedAt: Date(),
                        serverUserAgent: update.serverUserAgent
                    )
                    self.applyCodexPush(snapshot)
                } catch {
                    // Rolling notifications are sparse and advisory. A malformed one
                    // must not demote a valid snapshot; the safety poll remains active.
                    continue
                }
            }
        }
    }

    func applyCodexPush(_ snapshot: UsageSnapshot) {
        guard let mergedState = CodexRateLimitUpdatePolicy.applying(snapshot, to: state),
              let mergedSnapshot = mergedState.snapshot else { return }
        state = mergedState
        snapshotStore.save(mergedSnapshot)
        onVisualChange?()
    }

    /// Invalidates every result that was started under the previous executable path.
    /// The caller may defer refresh while it tears down provider-specific transport.
    @discardableResult
    func providerConfigurationChanged(refreshImmediately: Bool = true) -> UInt64 {
        let generation = advanceConfigurationGeneration()
        if let snapshot = state.snapshot {
            state = .stale(
                snapshot,
                reason: .transport("\(provider.displayName) CLI path changed; waiting to reconnect")
            )
            onVisualChange?()
        }
        if refreshImmediately, settings.isEnabled {
            requestRefresh(reason: .manual)
        }
        return generation
    }

    func refreshAfterConfigurationChange(_ generation: UInt64) {
        guard isCurrentConfiguration(generation), settings.isEnabled else { return }
        requestRefresh(reason: .manual)
    }

    func isCurrentConfiguration(_ generation: UInt64) -> Bool {
        configurationGeneration == generation
    }

    private func advanceConfigurationGeneration() -> UInt64 {
        configurationGeneration &+= 1
        return configurationGeneration
    }

    func requestRefresh(reason: FetchPacing.Reason) {
        guard settings.isEnabled, !isShuttingDown else { return }
        if refreshTask != nil {
            if reason == .manual { pendingRefreshReason = .manual }
            return
        }
        refreshTaskGeneration &+= 1
        let taskGeneration = refreshTaskGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(reason: reason)
            self.refreshTaskDidFinish(generation: taskGeneration)
        }
    }

    private func finishFetch() {
        isFetching = false
    }

    private func refreshTaskDidFinish(generation: UInt64) {
        guard refreshTaskGeneration == generation else { return }
        refreshTask = nil
        guard let pendingRefreshReason else { return }
        self.pendingRefreshReason = nil
        guard settings.isEnabled, !isShuttingDown else { return }
        requestRefresh(reason: pendingRefreshReason)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            cancelScheduledAttempt()
        } else {
            // Coming back from sleep or an unlock, whatever is on screen is old.
            requestRefresh(reason: .scheduled)
        }
    }

    private func cancelScheduledAttempt() {
        timer?.invalidate()
        timer = nil
        nextAttemptAt = nil
    }

    private func rescheduleTimer(
        after override: TimeInterval? = nil,
        reason: FetchPacing.Reason = .scheduled
    ) {
        cancelScheduledAttempt()
        guard settings.isEnabled, !isPaused else { return }

        // A failed fetch schedules the next attempt from the backoff, not the user's
        // interval. Honouring the interval while backing off would defeat the backoff.
        let delay = override ?? settings.refreshInterval.seconds
        nextAttemptAt = Date().addingTimeInterval(delay)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelScheduledAttempt()
                self.requestRefresh(reason: reason)
            }
        }
        // .common so the timer keeps firing while a menu or popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs the real fetch → state machine, whichever provider is behind it.
    ///
    /// The reentry latch is set before the `await`, not inside it: two clicks landing
    /// in the same turn would otherwise both pass the check.
    private func refresh(reason: FetchPacing.Reason = .scheduled) async {
        guard settings.isEnabled, !isShuttingDown else { return }
        guard !isFetching else {
            if reason == .manual { pendingRefreshReason = .manual }
            return
        }

        // Checked before the latch so a skipped call does not look like a fetch that
        // produced nothing.
        let decision = FetchPacing.decide(
            lastAttemptAt: lastAttemptAt,
            storedFetchedAt: state.snapshot?.fetchedAt,
            interval: settings.refreshInterval.seconds,
            reason: reason
        )
        switch decision {
        case .fetch:
            break
        case .useStored(let freshFor):
            // Still good. Let the timer run out the remainder instead of restarting it,
            // or relaunching would postpone every refresh indefinitely.
            rescheduleTimer(after: freshFor)
            return
        case .tooSoon(let retryAfter):
            rescheduleTimer(after: max(retryAfter, 1), reason: reason)
            return
        }

        let fetchGeneration = configurationGeneration
        isFetching = true
        defer { finishFetch() }

        state = .refreshing(previous: state.snapshot)
        onVisualChange?()
        lastAttemptAt = Date()

        do {
            let snapshot = try await makeProvider().fetch()
            guard fetchGeneration == configurationGeneration else { return }
            state = .current(snapshot)
            snapshotStore.save(snapshot)
            backoff.reset()
            consecutiveFailures = 0
            rescheduleTimer()
        } catch {
            guard fetchGeneration == configurationGeneration else { return }
            let usageError = (error as? UsageError) ?? .transport(error.localizedDescription)
            onDiagnosticError?(usageError)
            state = .afterFailure(usageError, previous: state.snapshot)
            if usageError.isExpectedLimitation {
                // Nothing to back off from. Retrying a provider that has no
                // implementation just accumulates a failure count that means nothing.
                backoff.reset()
                consecutiveFailures = 0
                cancelScheduledAttempt()
            } else {
                let delay = backoff.recordFailure()
                consecutiveFailures = backoff.consecutiveFailures
                rescheduleTimer(after: delay)
            }
        }
        onVisualChange?()
    }

    /// Stops scheduling and cancels the one provider fetch this presenter owns. The
    /// caller first begins shutdown for every presenter, then stops the shared Codex
    /// connection so its pending continuation can finish, and finally awaits this task.
    func beginShutdown() -> Task<Void, Never>? {
        guard !isShuttingDown else { return refreshTask }
        isShuttingDown = true
        _ = advanceConfigurationGeneration()
        pendingRefreshReason = nil
        cancelScheduledAttempt()
        codexUpdatesTask?.cancel()
        codexUpdatesTask = nil
        let task = refreshTask
        task?.cancel()
        return task
    }

    private func makeProvider() -> any UsageProvider {
        if let providerFactory {
            return providerFactory(
                provider,
                claudeExecutablePath(),
                codexExecutablePath()
            )
        }
        switch provider {
        case .claude:
            return ClaudeUsageProvider(
                locator: ClaudeExecutableLocator(configuredPath: claudeExecutablePath())
            )
        case .codex:
            return CodexUsageProvider(configuredExecutablePath: codexExecutablePath())
        }
    }

    func renderModel(locale: Locale = Locale(identifier: "en_US")) -> GaugeRenderModel {
        GaugeStyleResolver.renderModel(provider: provider, state: state, locale: locale)
    }

    var renderModel: GaugeRenderModel {
        renderModel()
    }
}
