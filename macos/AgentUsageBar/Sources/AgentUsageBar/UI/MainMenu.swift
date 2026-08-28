import AppKit

/// Builds the menu bar the app shows while the settings window is open.
///
/// A menu bar utility normally has no menu bar of its own. But opening settings
/// promotes the app to a regular one, and a regular app with an empty menu bar has no
/// ⌘W and no ⌘Q — the window becomes unclosable by keyboard and the app unquittable.
enum MainMenu {

    static func build(appName: String, language: AppLanguage) -> NSMenu {
        let root = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: language.text(chinese: "關於 \(appName)", english: "About \(appName)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: language.text(chinese: "隱藏 \(appName)", english: "Hide \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: language.text(chinese: "結束 \(appName)", english: "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        root.addItem(appMenuItem)

        // Edit menu: without it, ⌘C/⌘V do nothing in any text field the settings window
        // ever grows.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: language.text(chinese: "編輯", english: "Edit"))
        editMenu.addItem(withTitle: language.text(chinese: "剪下", english: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: language.text(chinese: "拷貝", english: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: language.text(chinese: "貼上", english: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: language.text(chinese: "全選", english: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        root.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: language.text(chinese: "視窗", english: "Window"))
        windowMenu.addItem(withTitle: language.text(chinese: "關閉", english: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: language.text(chinese: "縮到最小", english: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        root.addItem(windowMenuItem)

        return root
    }
}
