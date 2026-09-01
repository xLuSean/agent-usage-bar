#if DEBUG
import AppKit
import SwiftUI
import UsageMeterCore

/// Forces the popover through a real layout pass and renders it to a PNG.
///
/// Compiling a SwiftUI view proves nothing about whether its `body` runs: a bad
/// binding, a zero fitting size, or a `ScrollView` fighting the popover's fixed
/// content size all show up only when something asks for layout. §7.3 makes the
/// detail panel a hard requirement, so it needs to have actually run at least once.
@MainActor
enum PopoverRenderCheck {

    /// Chosen to exercise the structurally different layouts: the window list,
    /// recovery-time row, generic error banner, and Claude sign-in recovery action.
    static let scenarios: [DemoScenario] = [
        .healthy,
        .betweenWindows,
        .throttled,
        .outdatedReading,
        .notLoggedIn,
    ]

    /// Known limit of this check: a headless capture does not draw `NSTabView` chrome,
    /// so the settings window's tab strip is never in the PNG. What it does prove is
    /// that each tab's content lays out and draws. The strip itself needs a real
    /// on-screen look.

    static let contentSize = NSSize(width: 320, height: 400)
    static let settingsSize = NSSize(width: 460, height: 420)

    static func run(writingTo path: String?) -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures += 1 }
        }

        let model = AppModel(displayLanguage: .english)
        guard let presenter = model.presenter(for: .claude) else {
            print("FAIL Claude presenter not found")
            return 1
        }

        var images: [(String, NSImage, NSColor)] = []
        var settingsImages: [(String, NSImage, NSColor)] = []

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let isDark = appearanceName == .darkAqua
            // NSPopover supplies its own material, so the content view is transparent.
            // Painting a matching backdrop is the only way to judge text contrast.
            let backdrop = isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)

            for scenario in scenarios {
                presenter.applyDemoScenario(scenario)

                let host = NSHostingController(
                    rootView: UsagePopoverView(
                        presenter: presenter,
                        language: .english,
                        onOpenSettings: {}
                    )
                )
                host.view.appearance = appearance
                host.view.frame = NSRect(origin: .zero, size: contentSize)
                host.view.layoutSubtreeIfNeeded()

                let fitting = host.view.fittingSize
                let label = "\(scenario.title) / \(isDark ? "Dark" : "Light")"
                check(fitting.height > 0, "\(label): popover has nonzero height (\(Int(fitting.height)))")
                check(fitting.width > 0, "\(label): popover has nonzero width (\(Int(fitting.width)))")

                guard let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else {
                    check(false, "\(label): could not create bitmap rep")
                    continue
                }
                appearance.performAsCurrentDrawingAppearance {
                    host.view.cacheDisplay(in: host.view.bounds, to: rep)
                }

                // A panel that laid out but drew nothing is the failure this is looking for.
                check(rep.pixelsHigh > 0 && rep.pixelsWide > 0,
                      "\(label): rendered \(rep.pixelsWide)×\(rep.pixelsHigh) pixels")

                let image = NSImage(size: contentSize)
                image.addRepresentation(rep)
                images.append((label, image, backdrop))
            }
        }

        // The combined popover is a different view arrangement from the single one, and
        // the bug it replaces was invisible to compilation: it picked a provider to
        // show and always picked the wrong one.
        do {
            let appearance = NSAppearance(named: .darkAqua)!
            for presenter in model.presenters {
                presenter.applyDemoScenario(.healthy)
            }
            let host = NSHostingController(
                rootView: UsagePopoverView(
                    presenters: model.presenters,
                    language: .english,
                    allowsScrolling: false,
                    onOpenSettings: {}
                )
            )
            host.view.appearance = appearance
            let measured = host.sizeThatFits(in: NSSize(width: 320, height: 10_000))
            let combinedSize = NSSize(width: 320, height: ceil(measured.height))
            host.view.frame = NSRect(origin: .zero, size: combinedSize)
            host.view.layoutSubtreeIfNeeded()
            check(host.view.fittingSize.height > 0, "Combined popover has nonzero height (\(Int(host.view.fittingSize.height)))")
            check(combinedSize.height > 460, "Combined popover expands to fit full content (\(Int(combinedSize.height)) pt)")

            if let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                appearance.performAsCurrentDrawingAppearance {
                    host.view.cacheDisplay(in: host.view.bounds, to: rep)
                }
                check(rep.pixelsHigh > 0, "Combined popover rendered \(rep.pixelsWide)×\(rep.pixelsHigh) pixels")
                let image = NSImage(size: combinedSize)
                image.addRepresentation(rep)
                images.append(("Combined popover / Dark", image, NSColor(white: 0.16, alpha: 1)))
            } else {
                check(false, "Combined popover: could not create bitmap rep")
            }
        }

        // One Chinese popover exercises the app-selected locale through the same view
        // and domain-formatting path. English remains the longest-copy stress pass.
        do {
            let chineseModel = AppModel(displayLanguage: .traditionalChinese)
            guard let chinesePresenter = chineseModel.presenter(for: .claude) else {
                check(false, "Traditional Chinese: Claude presenter not found")
                return 1
            }
            // Exercises the translated copy-only sign-in recovery surface.
            chinesePresenter.applyDemoScenario(.notLoggedIn)
            let appearance = NSAppearance(named: .aqua)!
            let host = NSHostingController(
                rootView: UsagePopoverView(
                    presenter: chinesePresenter,
                    language: .traditionalChinese,
                    onOpenSettings: {}
                )
            )
            host.view.appearance = appearance
            host.view.frame = NSRect(origin: .zero, size: contentSize)
            host.view.layoutSubtreeIfNeeded()
            let label = "繁體中文 / Light"
            check(host.view.fittingSize.height > 0, "\(label): popover has nonzero height")
            if let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                appearance.performAsCurrentDrawingAppearance {
                    host.view.cacheDisplay(in: host.view.bounds, to: rep)
                }
                check(rep.pixelsHigh > 0, "\(label): rendered \(rep.pixelsWide)×\(rep.pixelsHigh) pixels")
                let image = NSImage(size: contentSize)
                image.addRepresentation(rep)
                images.append((label, image, NSColor(white: 0.96, alpha: 1)))
            } else {
                check(false, "\(label): could not create bitmap rep")
            }
        }

        // The settings window has the same problem the popover had: compiled, never
        // rendered. It is also where every preference now lives, so a Form that fails to
        // lay out would leave the app with no way to change anything.
        for language in AppLanguage.allCases {
            let settingsModel = AppModel(displayLanguage: language)
            settingsModel.menuBarPlacement = { _ in .combined }
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = NSAppearance(named: appearanceName)!
                let isDark = appearanceName == .darkAqua
                let backdrop = isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
                let size = settingsSize

            // Build the window exactly the way SettingsWindowController does, minus the
            // showing. Assigning contentViewController is what resizes the window to fit
            // its content, so this is the only way to learn the real dimensions —
            // measuring a detached hosting view clips the TabView's tab strip.
                let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
                window.appearance = appearance
                let hosting = NSHostingController(rootView: SettingsView(model: settingsModel))
                window.contentViewController = hosting
                window.setContentSize(NSSize(
                width: max(hosting.view.fittingSize.width, SettingsView.contentSize.width),
                height: max(hosting.view.fittingSize.height, SettingsView.contentSize.height + 44)
            ))
                window.layoutIfNeeded()
                guard let content = window.contentView else {
                    check(false, "Settings window: missing contentView")
                    continue
                }
                content.layoutSubtreeIfNeeded()

                let bounds = content.bounds
                let label = "Settings / \(language.displayName) / \(isDark ? "Dark" : "Light") (\(Int(bounds.width))×\(Int(bounds.height)))"
                check(bounds.height > 0 && bounds.width > 0, "\(label): content area has a real size")
                check(bounds.width >= SettingsView.contentSize.width,
                      "\(label): width is sufficient (must be ≥ \(Int(SettingsView.contentSize.width)))")

                guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
                    check(false, "\(label): could not create bitmap rep")
                    continue
                }
                appearance.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in: bounds, to: rep)
                }
                check(rep.pixelsHigh > 0 && rep.pixelsWide > 0,
                      "\(label): rendered \(rep.pixelsWide)×\(rep.pixelsHigh) pixels")

                let image = NSImage(size: bounds.size)
                image.addRepresentation(rep)
                settingsImages.append((label, image, backdrop))
            }
        }

        // Render the new expanded diagnostic state directly. The ordinary settings
        // pass starts on Providers, so it cannot prove that a disclosure row, wrapped
        // detail text, and copy button fit inside the shipping settings window.
        do {
            let suiteName = "io.github.sean.AgentUsageBar.render.diagnostics.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = DiagnosticLogStore(defaults: defaults)
            _ = store.append(
                provider: .claude,
                error: .schemaChanged("Missing the \"Current week (all models)\" line"),
                now: Date()
            )
            let diagnosticsModel = AppModel(
                displayLanguage: .english,
                diagnosticLogStore: store
            )
            let expandedIDs = Set(diagnosticsModel.diagnosticEntries.map(\.id))
            let appearance = NSAppearance(named: .darkAqua)!
            let backdrop = NSColor(white: 0.16, alpha: 1)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: settingsSize),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let hosting = NSHostingController(rootView: SettingsView(
                model: diagnosticsModel,
                initialTab: .diagnostics,
                initiallyExpandedDiagnosticEntryIDs: expandedIDs
            ))
            window.contentViewController = hosting
            window.setContentSize(NSSize(
                width: max(hosting.view.fittingSize.width, SettingsView.contentSize.width),
                height: max(hosting.view.fittingSize.height, SettingsView.contentSize.height + 44)
            ))
            window.layoutIfNeeded()

            guard let content = window.contentView else {
                check(false, "Settings / Diagnostics expanded: missing contentView")
                return 1
            }
            content.layoutSubtreeIfNeeded()
            let bounds = content.bounds
            let label = "Settings / Diagnostics expanded / English / Dark (\(Int(bounds.width))×\(Int(bounds.height)))"
            check(bounds.height > 0 && bounds.width >= SettingsView.contentSize.width,
                  "\(label): content area fits the settings window")
            guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
                check(false, "\(label): could not create bitmap rep")
                return 1
            }
            appearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: bounds, to: rep)
            }
            check(rep.pixelsHigh > 0 && rep.pixelsWide > 0,
                  "\(label): rendered \(rep.pixelsWide)×\(rep.pixelsHigh) pixels")
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            settingsImages.append((label, image, backdrop))
        }

        if let path, !images.isEmpty {
            do {
                let popoverCellSize = NSSize(
                    width: contentSize.width,
                    height: images.map { $0.1.size.height }.max() ?? contentSize.height
                )
                try writeStrip(images, cellSize: popoverCellSize, to: path)
                print("wrote \(path)")
                let settingsPath = path.replacingOccurrences(of: ".png", with: "-settings.png")
                let settingsCell = settingsImages.first?.1.size ?? settingsSize
                try writeStrip(settingsImages, cellSize: settingsCell, to: settingsPath)
                print("wrote \(settingsPath)")
            } catch {
                check(false, "Failed to write PNG: \(error)")
            }
        }

        print(failures == 0 ? "\npopover render check passed" : "\npopover render check FAILED: \(failures) items")
        return failures == 0 ? 0 : 1
    }

    private static func writeStrip(_ images: [(String, NSImage, NSColor)], cellSize contentSize: NSSize, to path: String) throws {
        let labelHeight: CGFloat = 26
        let gap: CGFloat = 12
        let columns = scenarios.count
        let rows = (images.count + columns - 1) / columns
        let width = (contentSize.width + gap) * CGFloat(columns) + gap
        let height = (contentSize.height + labelHeight + gap) * CGFloat(rows) + gap

        let sheet = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor(white: 0.82, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

            for (index, entry) in images.enumerated() {
                let column = index % columns
                let row = index / columns
                let x = gap + (contentSize.width + gap) * CGFloat(column)
                let y = gap + (contentSize.height + labelHeight + gap) * CGFloat(row)

                NSAttributedString(
                    string: entry.0,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: NSColor.black,
                    ]
                ).draw(at: NSPoint(x: x, y: y))

                let rect = NSRect(
                    x: x,
                    y: y + labelHeight,
                    width: entry.1.size.width,
                    height: entry.1.size.height
                )
                entry.2.setFill()
                NSBezierPath(rect: rect).fill()
                entry.1.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: true, hints: [:])
            }
            return true
        }

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
