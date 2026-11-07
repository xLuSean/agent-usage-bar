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
    typealias ScheduleTimer = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Timer

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
                rescheduleCodexTokenTimer()
            }
            if enabledChanged {
                let generation = advanceConfigurationGeneration()
                if settings.isEnabled {
                    requestRefresh(reason: .manual)
                } else {
                    pendingRefreshReason = nil
                    pendingCodexTokenRefreshReason = nil
                    codexTokenRefreshTask?.cancel()
                    codexTokenRefreshTask = nil
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

    var codexTokenRefreshInterval: CodexTokenRefreshInterval {
        didSet {
            guard provider == .codex,
                  codexTokenRefreshInterval != oldValue else { return }
            SettingsStore.saveCodexTokenRefreshInterval(codexTokenRefreshInterval)
            rescheduleCodexTokenTimer()
            requestCodexTokenRefresh(reason: .scheduled)
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
    private var codexTokenRefreshTaskGeneration: UInt64 = 0
    private var pendingCodexTokenRefreshReason: FetchPacing.Reason?
    private var codexTokenRefreshTask: Task<Void, Never>?
    private var codexTokenLastAttemptAt: Date?
    private var pendingCodexAccountUsage: CodexAccountUsage?
    private let snapshotStore: UsageSnapshotStore
    private let providerFactory: ProviderFactory?
    private let now: @MainActor () -> Date
    private let scheduleTimer: ScheduleTimer
    private var timer: Timer?
    private var codexTokenTimer: Timer?
    /// Set while the screen is locked or the machine is asleep. Polling an endpoint that
    /// rate limits per token while nobody is looking spends the budget for nothing.
    private var isPaused = false
    private var codexUpdatesTask: Task<Void, Never>?

    /// Called when anything that affects the drawn icon changes.
    var onVisualChange: (() -> Void)?

    /// Supplied by AppModel. Only accepted fetch failures reach this callback; malformed
    /// advisory pushes remain ignored and cannot flood the persisted diagnostic log.
    var onDiagnosticError: ((UsageError, CodexQueryDiagnostic?) -> Void)?
    var onCodexQuerySuccess: ((CodexQueryDiagnostic) -> Void)?

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
        providerFactory: ProviderFactory? = nil,
        now: @escaping @MainActor () -> Date = Date.init,
        scheduleTimer: @escaping ScheduleTimer = { delay, action in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            // Keep polling while a menu or popover is tracking.
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    ) {
        self.provider = provider
        self.settings = SettingsStore.load(provider)
        self.codexTokenRefreshInterval = SettingsStore.loadCodexTokenRefreshInterval()
        self.backoff = RetryBackoff(policy: .forProvider(provider))
        self.snapshotStore = snapshotStore
        self.providerFactory = providerFactory
        self.now = now
        self.scheduleTimer = scheduleTimer

        // Start from what was already known rather than from nothing. A relaunch used
        // to blank the gauge and immediately ask again; the reading it threw away was
        // usually still good.
        if let stored = snapshotStore.load(provider) {
            let age = now().timeIntervalSince(stored.fetchedAt)
            state = age < settings.refreshInterval.seconds
                ? .current(stored)
                : .stale(stored, reason: .transport("Data is from the previous app session"))
        }
    }

    #if DEBUG
    /// Diagnostic-only state injection. Release does not compile `DemoScenario` or any
    /// fixture/live branch into the presenter.
    func applyDemoScenario(_ scenario: DemoScenario) {
        state = scenario.state(provider: provider)
        backoff.reset()
        consecutiveFailures = 0
        cancelScheduledAttempt()
        cancelCodexTokenScheduledAttempt()
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
        rescheduleCodexTokenTimer()
    }

    private func subscribeToCodexUpdatesIfNeeded() {
        guard provider == .codex, codexUpdatesTask == nil else { return }
        let updates = CodexAppServerClient.shared.rateLimitUpdates
        codexUpdatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { return }
                guard self.settings.isEnabled, !self.isPaused else { continue }
                guard update.isNotification(fromConfiguredPath: self.codexExecutablePath()) else { continue }
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
        if provider == .codex {
            // A different CLI may read a different account. Drop both readings before
            // the first quota or token result can arrive, including across relaunch.
            snapshotStore.clear(.codex)
            state = .starting
            onVisualChange?()
        } else if let snapshot = state.snapshot {
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
        pendingCodexAccountUsage = nil
        backoff.reset()
        consecutiveFailures = 0
        return configurationGeneration
    }

    func requestRefresh(reason: FetchPacing.Reason) {
        requestCodexTokenRefresh(reason: reason)
        requestQuotaRefresh(reason: reason)
    }

    private func requestQuotaRefresh(reason: FetchPacing.Reason) {
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
        requestQuotaRefresh(reason: pendingRefreshReason)
    }

    private func requestCodexTokenRefresh(reason: FetchPacing.Reason) {
        guard provider == .codex,
              providerFactory == nil,
              settings.isEnabled,
              !isShuttingDown else { return }
        if codexTokenRefreshTask != nil {
            if reason == .manual { pendingCodexTokenRefreshReason = .manual }
            return
        }
        codexTokenRefreshTaskGeneration &+= 1
        let taskGeneration = codexTokenRefreshTaskGeneration
        codexTokenRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCodexTokenUsage(reason: reason)
            self.codexTokenRefreshTaskDidFinish(generation: taskGeneration)
        }
    }

    private func codexTokenRefreshTaskDidFinish(generation: UInt64) {
        guard codexTokenRefreshTaskGeneration == generation else { return }
        codexTokenRefreshTask = nil
        guard let pendingCodexTokenRefreshReason else { return }
        self.pendingCodexTokenRefreshReason = nil
        guard settings.isEnabled, !isShuttingDown else { return }
        requestCodexTokenRefresh(reason: pendingCodexTokenRefreshReason)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            cancelScheduledAttempt()
            cancelCodexTokenScheduledAttempt()
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

    private func cancelCodexTokenScheduledAttempt() {
        codexTokenTimer?.invalidate()
        codexTokenTimer = nil
    }

    private func rescheduleTimer(
        after override: TimeInterval? = nil,
        reason: FetchPacing.Reason = .scheduled
    ) {
        cancelScheduledAttempt()
        guard settings.isEnabled, !isPaused else { return }

        // A failed fetch schedules the next attempt from the backoff, not the user's
        // interval. Honouring the interval while backing off would defeat the backoff.
        let scheduledAt = now()
        let delay = override ?? backoff.remainingDelay(at: scheduledAt) ?? settings.refreshInterval.seconds
        nextAttemptAt = scheduledAt.addingTimeInterval(delay)
        timer = scheduleTimer(delay) { [weak self] in
            guard let self else { return }
            self.cancelScheduledAttempt()
            self.requestQuotaRefresh(reason: reason)
        }
    }

    private func rescheduleCodexTokenTimer(
        after override: TimeInterval? = nil,
        reason: FetchPacing.Reason = .scheduled
    ) {
        cancelCodexTokenScheduledAttempt()
        guard provider == .codex, settings.isEnabled, !isPaused else { return }

        let delay = override ?? codexTokenRefreshInterval.seconds
        codexTokenTimer = scheduleTimer(delay) { [weak self] in
            guard let self else { return }
            self.cancelCodexTokenScheduledAttempt()
            self.requestCodexTokenRefresh(reason: reason)
        }
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
        let attemptTime = now()
        if reason == .scheduled, let remaining = backoff.remainingDelay(at: attemptTime), remaining > 0 {
            rescheduleTimer(after: remaining)
            return
        }
        let decision = FetchPacing.decide(
            lastAttemptAt: lastAttemptAt,
            storedFetchedAt: backoff.consecutiveFailures == 0 ? state.snapshot?.fetchedAt : nil,
            interval: settings.refreshInterval.seconds,
            reason: reason,
            now: attemptTime
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
        lastAttemptAt = attemptTime

        do {
            var snapshot: UsageSnapshot
            if provider == .codex, providerFactory == nil {
                let reading = try await makeCodexProvider().quotaReading(
                    preserving: pendingCodexAccountUsage ?? state.snapshot?.codexAccountUsage
                )
                guard fetchGeneration == configurationGeneration else { return }
                snapshot = reading.snapshot
                if let query = reading.query { onCodexQuerySuccess?(query) }
                // A token response may have completed while the quota read was in
                // flight. Apply the newest accepted value before publishing.
                if let pendingCodexAccountUsage {
                    snapshot = snapshot.replacingCodexAccountUsage(pendingCodexAccountUsage)
                    self.pendingCodexAccountUsage = nil
                }
            } else {
                snapshot = try await makeProvider().fetch()
                guard fetchGeneration == configurationGeneration else { return }
            }
            state = .current(snapshot)
            snapshotStore.save(snapshot)
            backoff.reset()
            consecutiveFailures = 0
            rescheduleTimer()
        } catch {
            guard fetchGeneration == configurationGeneration else { return }
            let usageError = recordDiagnostic(error)
            state = .afterFailure(usageError, previous: state.snapshot)
            if usageError.isExpectedLimitation {
                // Nothing to back off from. Retrying a provider that has no
                // implementation just accumulates a failure count that means nothing.
                backoff.reset()
                consecutiveFailures = 0
                cancelScheduledAttempt()
            } else {
                let delay = backoff.recordFailure(at: now())
                consecutiveFailures = backoff.consecutiveFailures
                rescheduleTimer(after: delay)
            }
        }
        onVisualChange?()
    }

    /// Refreshes only `account/usage/read`. Its pacing, timer, and persisted timestamp
    /// are independent from quota; failure leaves the last trusted token reading intact.
    private func refreshCodexTokenUsage(reason: FetchPacing.Reason) async {
        guard provider == .codex, settings.isEnabled, !isShuttingDown else { return }

        let decision = FetchPacing.decide(
            lastAttemptAt: codexTokenLastAttemptAt,
            // A failed token read also starts a full interval. On relaunch only the
            // persisted successful reading is available as a scheduling reference.
            storedFetchedAt: codexTokenLastAttemptAt ?? pendingCodexAccountUsage?.fetchedAt
                ?? state.snapshot?.codexAccountUsage?.fetchedAt,
            interval: codexTokenRefreshInterval.seconds,
            reason: reason,
            now: now()
        )
        switch decision {
        case .fetch:
            break
        case .useStored(let freshFor):
            rescheduleCodexTokenTimer(after: freshFor)
            return
        case .tooSoon(let retryAfter):
            rescheduleCodexTokenTimer(after: max(retryAfter, 1), reason: reason)
            return
        }

        let fetchGeneration = configurationGeneration
        let fetchedAt = now()
        codexTokenLastAttemptAt = fetchedAt
        do {
            let reading = try await makeCodexProvider().tokenReading(fetchedAt: fetchedAt)
            guard fetchGeneration == configurationGeneration else { return }
            let accountUsage = reading.usage
            if let query = reading.query { onCodexQuerySuccess?(query) }
            pendingCodexAccountUsage = accountUsage
            if let mergedState = CodexAccountUsageUpdatePolicy.applying(accountUsage, to: state),
               let mergedSnapshot = mergedState.snapshot {
                state = mergedState
                snapshotStore.save(mergedSnapshot)
            }
            rescheduleCodexTokenTimer()
            onVisualChange?()
        } catch is CancellationError {
            return
        } catch {
            guard fetchGeneration == configurationGeneration else { return }
            _ = recordDiagnostic(error)
            // This optional surface must not demote quota or erase the previous token
            // result. Try again on its own normal cadence.
            rescheduleCodexTokenTimer()
        }
    }

    private func recordDiagnostic(_ error: any Error) -> UsageError {
        let failure = error as? CodexQueryFailure
        let usageError = failure?.error ?? (error as? UsageError) ?? .transport(error.localizedDescription)
        onDiagnosticError?(usageError, failure?.diagnostic)
        return usageError
    }

    /// Stops scheduling and cancels the provider fetches this presenter owns. The
    /// caller first begins shutdown for every presenter, then stops the shared Codex
    /// connection so pending continuations can finish, and finally awaits both tasks.
    func beginShutdown() -> [Task<Void, Never>] {
        guard !isShuttingDown else {
            return [refreshTask, codexTokenRefreshTask].compactMap { $0 }
        }
        isShuttingDown = true
        _ = advanceConfigurationGeneration()
        pendingRefreshReason = nil
        pendingCodexTokenRefreshReason = nil
        cancelScheduledAttempt()
        cancelCodexTokenScheduledAttempt()
        codexUpdatesTask?.cancel()
        codexUpdatesTask = nil
        let tasks = [refreshTask, codexTokenRefreshTask].compactMap { $0 }
        for task in tasks { task.cancel() }
        return tasks
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

    private func makeCodexProvider() -> CodexUsageProvider {
        CodexUsageProvider(configuredExecutablePath: codexExecutablePath())
    }

    func renderModel(locale: Locale = Locale(identifier: "en_US")) -> GaugeRenderModel {
        GaugeStyleResolver.renderModel(provider: provider, state: state, locale: locale)
    }

    var renderModel: GaugeRenderModel {
        renderModel()
    }
}
