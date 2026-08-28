import AppKit
import UsageMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Owned once, here, and injected everywhere else. A second instance would give the
    /// settings window a different copy of the state than the menu bar is showing.
    private let model = AppModel()
    private var statusBar: StatusBarController?
    private var settings: SettingsWindowController?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appName: "Agent Usage Bar", language: model.displayLanguage)

        let settings = SettingsWindowController(model: model)
        self.settings = settings
        statusBar = StatusBarController(model: model, onOpenSettings: { [weak settings] in
            settings?.show()
        })
        model.onLanguageChange = { [weak self, weak settings] in
            guard let self else { return }
            NSApp.mainMenu = MainMenu.build(appName: "Agent Usage Bar", language: self.model.displayLanguage)
            self.statusBar?.languageDidChange()
            settings?.languageDidChange()
        }

        observeSystemEvents()
        model.refreshAll()
        model.startPolling()
    }

    /// Sleep and lock reasons can overlap. Polling resumes only after every active
    /// reason clears, then asks for a fresh reading under the normal pacing rules.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.model.setPaused(true, for: .systemSleep) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.model.setPaused(false, for: .systemSleep) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.model.setPaused(true, for: .displaySleep) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.model.setPaused(false, for: .displaySleep) }
        })

        // Screen lock is not on NSWorkspace's centre; it only arrives as a distributed
        // notification, and its name is not a public constant.
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: AppInstanceCoordinator.showSettingsNotification,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings?.show() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.model.setPaused(true, for: .screenLock) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.model.setPaused(false, for: .screenLock) }
        })
    }

    /// Double-clicking the app in Finder or the Dock while it is already running.
    ///
    /// Without this the second launch does nothing visible and the app looks broken —
    /// there is no window to bring forward and no Dock icon to bounce.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settings?.show()
        return true
    }

    /// Closing the settings window leaves the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.stop()
            await MainActor.run { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
    }
}
