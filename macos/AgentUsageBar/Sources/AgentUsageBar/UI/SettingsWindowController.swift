import AppKit
import SwiftUI

/// Owns the settings window and the Dock icon that comes with it.
///
/// The app launches as a menu bar utility with no Dock icon. Opening settings promotes
/// it to a regular app so the window gets a Dock icon and a menu bar of its own;
/// closing the window demotes it again. The status item is unaffected either way, so
/// the gauges stay put whether the window is open, closed, or never opened.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        // Promote before ordering the window front, or the window appears while the app
        // is still an accessory and cannot take focus properly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    func languageDidChange() {
        window?.title = windowTitle
    }

    private var windowTitle: String {
        model.displayLanguage.text(chinese: "Agent Usage Bar 設定", english: "Agent Usage Bar Settings")
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = windowTitle
        // Let the content decide the size, then freeze it. The tab strip's height is not
        // something worth hard-coding — it changes with the system font size.
        // Fitting size plus a floor. SwiftUI's TabView does not always report its tab
        // strip's height, so sizing purely to fit can leave the strip eating into the
        // content. The floor costs nothing and removes the failure mode.
        let fitting = hosting.view.fittingSize
        window.setContentSize(NSSize(
            width: max(fitting.width, SettingsView.contentSize.width),
            height: max(fitting.height, SettingsView.contentSize.height + 44)
        ))
        window.styleMask = [.titled, .closable, .miniaturizable]
        Self.configureDesktopBehavior(of: window)
        // Closing settings must not destroy the window: the app keeps running in the
        // menu bar and the same window is reopened next time.
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// A reused window otherwise remains assigned to the Space where it was first
    /// shown. Moving it to the active Space makes “設定…” act where the user clicked,
    /// instead of switching them back to an earlier desktop.
    static func configureDesktopBehavior(of window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar utility. Deferred because demoting while the window is
        // still tearing down leaves the Dock icon stuck.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
