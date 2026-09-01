import AppKit
import Observation
import UsageMeterCore

/// The app's single state owner. Created once by the delegate and handed to every
/// scene, so a popover and a settings panel can never end up watching different copies.
@MainActor
@Observable
final class AppModel {

    let presenters: [ProviderPresenter]

    /// Set by the status bar controller so Settings can report where each gauge ended
    /// up. Optional because the model outlives any particular controller.
    var menuBarPlacement: (@MainActor (ProviderKind) -> StatusBarController.MenuBarPlacement)?

    /// True when the user has switched every provider off. The menu bar then shows a
    /// neutral entry point instead of nothing at all.
    var allProvidersDisabled: Bool {
        presenters.allSatisfy { !$0.settings.isEnabled }
    }

    var enabledPresenters: [ProviderPresenter] {
        presenters.filter { $0.settings.isEnabled }
    }

    var menuBarLayout: MenuBarLayout {
        didSet {
            guard menuBarLayout != oldValue else { return }
            SettingsStore.saveLayout(menuBarLayout)
            onLayoutChange?()
        }
    }

    var displayLanguage: AppLanguage {
        didSet {
            guard displayLanguage != oldValue else { return }
            SettingsStore.saveLanguage(displayLanguage)
            onLanguageChange?()
        }
    }

    var diagnosticRetention: DiagnosticRetentionPeriod {
        didSet {
            guard diagnosticRetention != oldValue else { return }
            diagnosticEntries = diagnosticLogStore.saveRetention(diagnosticRetention)
        }
    }

    var codexTokenHistoryPeriod: CodexTokenHistoryPeriod {
        didSet {
            guard codexTokenHistoryPeriod != oldValue else { return }
            SettingsStore.saveCodexTokenHistoryPeriod(codexTokenHistoryPeriod)
        }
    }

    private(set) var diagnosticEntries: [DiagnosticLogEntry]

    var onLayoutChange: (() -> Void)?
    var onLanguageChange: (() -> Void)?

    private(set) var claudeExecutablePath: String
    private(set) var codexExecutablePath: String
    private var pollingPauseState = PollingPauseState()
    private let diagnosticLogStore: DiagnosticLogStore

    var isPollingPaused: Bool { pollingPauseState.isPaused }

    /// `displayLanguage` is used by deterministic render checks. Normal app startup
    /// passes nil and loads the persisted preference.
    init(
        displayLanguage: AppLanguage? = nil,
        presenters: [ProviderPresenter]? = nil,
        diagnosticLogStore: DiagnosticLogStore = DiagnosticLogStore()
    ) {
        self.presenters = presenters ?? ProviderKind.allCases.map(ProviderPresenter.init(provider:))
        self.diagnosticLogStore = diagnosticLogStore
        menuBarLayout = SettingsStore.loadLayout()
        self.displayLanguage = displayLanguage ?? SettingsStore.loadLanguage()
        claudeExecutablePath = SettingsStore.loadClaudeExecutablePath()
        codexExecutablePath = SettingsStore.loadCodexExecutablePath()
        codexTokenHistoryPeriod = SettingsStore.loadCodexTokenHistoryPeriod()
        let loadedDiagnosticRetention = diagnosticLogStore.loadRetention()
        diagnosticRetention = loadedDiagnosticRetention
        diagnosticEntries = diagnosticLogStore.load(retention: loadedDiagnosticRetention)

        // After every stored property, not before: a closure capturing self cannot be
        // formed while any of them is still uninitialised.
        for presenter in self.presenters {
            presenter.claudeExecutablePath = { [weak self] in
                let path = self?.claudeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return path.isEmpty ? nil : path
            }
            presenter.codexExecutablePath = { [weak self] in
                let path = self?.codexExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return path.isEmpty ? nil : path
            }
            presenter.onDiagnosticError = { [weak self, provider = presenter.provider] error in
                guard let self else { return }
                self.diagnosticEntries = self.diagnosticLogStore.append(
                    provider: provider,
                    error: error
                )
            }
        }
    }

    func clearDiagnosticLog() {
        diagnosticLogStore.clear()
        diagnosticEntries = []
    }

    func setClaudeExecutablePath(_ path: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != claudeExecutablePath else { return }
        claudeExecutablePath = normalized
        SettingsStore.saveClaudeExecutablePath(normalized)
        // No connection to tear down: each query is its own short-lived process.
        presenter(for: .claude)?.providerConfigurationChanged()
    }

    func setCodexExecutablePath(_ path: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != codexExecutablePath else { return }
        codexExecutablePath = normalized
        SettingsStore.saveCodexExecutablePath(normalized)
        guard let codex = presenter(for: .codex) else { return }
        let generation = codex.providerConfigurationChanged(refreshImmediately: false)
        Task {
            guard codex.isCurrentConfiguration(generation) else { return }
            await CodexAppServerClient.shared.stop()
            codex.refreshAfterConfigurationChange(generation)
        }
    }

    func presenter(for provider: ProviderKind) -> ProviderPresenter? {
        presenters.first { $0.provider == provider }
    }

    /// Each provider refreshes on its own task. One provider being down, throttled, or
    /// unimplemented must not hold up or degrade the other.
    func refreshAll() {
        for presenter in enabledPresenters {
            presenter.requestRefresh(reason: .scheduled)
        }
    }

    func startPolling() {
        for presenter in presenters { presenter.startPolling() }
    }

    func setPaused(_ paused: Bool, for reason: PollingPauseState.Reason) {
        guard pollingPauseState.set(paused, for: reason) else { return }
        for presenter in presenters { presenter.setPaused(pollingPauseState.isPaused) }
    }

    /// Freezes every app-owned scheduler, cancels in-flight provider work, then waits
    /// for both the shared Codex root and every presenter task to finish. AppKit must not
    /// receive its termination reply before this returns.
    func stop() async {
        let refreshTasks = presenters.flatMap { $0.beginShutdown() }
        await CodexAppServerClient.shared.stop()
        for task in refreshTasks {
            await task.value
        }
    }
}
