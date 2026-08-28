import AppKit
import SwiftUI
import UsageMeterCore

/// Owns the menu bar items.
///
/// Owns either one `NSStatusItem` per enabled provider or one combined item, depending
/// on the user's placement setting. A neutral item appears only when every provider is
/// off, because otherwise turning both off removes the only way back into Settings.
@MainActor
final class StatusBarController: NSObject {

    private let model: AppModel
    private let onOpenSettings: () -> Void
    private var providerItems: [ProviderKind: NSStatusItem] = [:]
    private var combinedItem: NSStatusItem?
    private var combinedPopover: NSPopover?
    private var neutralItem: NSStatusItem?
    private var popovers: [ProviderKind: NSPopover] = [:]
    private var appearanceObservation: NSKeyValueObservation?

    struct PopoverLayoutDecision: Equatable {
        let height: CGFloat
        let usesScrolling: Bool
    }

    /// Use the content's natural height whenever the active screen can hold it. A
    /// scroll view is only the fallback for unusually short screens or unusually long
    /// error/detail content.
    static func popoverLayout(desiredHeight: CGFloat, availableHeight: CGFloat) -> PopoverLayoutDecision {
        let safeAvailable = availableHeight.isFinite && availableHeight > 0 ? availableHeight : 700
        let maximum = max(120, floor(safeAvailable - 24))
        let minimum = min(180, maximum)
        let safeDesired = desiredHeight.isFinite && desiredHeight > 0 ? ceil(desiredHeight) : minimum
        return PopoverLayoutDecision(
            height: min(max(safeDesired, minimum), maximum),
            usesScrolling: safeDesired > maximum
        )
    }

    init(model: AppModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        super.init()
        model.menuBarPlacement = { [weak self] provider in
            self?.placement(for: provider) ?? .disabled
        }
        model.onLayoutChange = { [weak self] in
            self?.rebuildItems()
        }
        for presenter in model.presenters {
            presenter.onVisualChange = { [weak self] in
                self?.synchronize()
            }
        }
        // The gauge is deliberately not a template image, so AppKit will not re-tint it
        // for a light or dark menu bar. Re-render on appearance change instead.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            // KVO delivers on whichever thread made the change. Hop explicitly rather
            // than assert — `assumeIsolated` traps when the assumption is wrong, and a
            // trap here would take the whole app down over an icon repaint.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateImages() }
            }
        }
        synchronize()
    }

    /// What the menu bar layer actually holds right now. Used by the self-test and by
    /// Settings, because "the item exists" and "the item is on screen" are different
    /// claims — and when they disagree, the user sees nothing and has no way to tell
    /// a bug from a full menu bar.
    var diagnostics: [(provider: ProviderKind, exists: Bool, isVisible: Bool, hasImage: Bool, autosaveName: String?)] {
        model.presenters.map { presenter in
            let item = providerItems[presenter.provider]
            return (
                provider: presenter.provider,
                exists: item != nil,
                isVisible: item?.isVisible ?? false,
                hasImage: item?.button?.image != nil,
                autosaveName: item?.autosaveName
            )
        }
    }

    /// Where a provider's gauge actually is.
    ///
    /// macOS gives no callback for "your status item did not fit". When the menu bar is
    /// full the item is still created and still reports `isVisible == true`; its window
    /// simply ends up somewhere that is not on a screen. Comparing the button window's
    /// frame against the screens is the only way to notice.
    func placement(for provider: ProviderKind) -> MenuBarPlacement {
        let isEnabled = model.presenter(for: provider)?.settings.isEnabled == true
        let item = model.menuBarLayout == .combined ? combinedItem : providerItems[provider]
        return Self.providerPlacement(
            isEnabled: isEnabled,
            layout: model.menuBarLayout,
            itemPlacement: placement(of: item)
        )
    }

    static func providerPlacement(
        isEnabled: Bool,
        layout: MenuBarLayout,
        itemPlacement: MenuBarPlacement
    ) -> MenuBarPlacement {
        guard isEnabled else { return .disabled }
        if layout == .combined, itemPlacement == .onScreen { return .combined }
        return itemPlacement
    }

    private func placement(of item: NSStatusItem?) -> MenuBarPlacement {
        guard let item else { return .notPlacedYet }
        guard item.isVisible else { return .hiddenByUser }
        guard let window = item.button?.window else { return .notPlacedYet }
        let frame = window.frame
        guard frame.width > 0 else { return .noRoom }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            return .noRoom
        }

        // Being inside the screen's bounds is not the same as being visible. The notch
        // sits inside those bounds too, so an item that slid behind it passes a naive
        // on-screen test while showing nothing.
        //
        // Status items live in the region to the *right* of the notch, laid out
        // right-to-left. The left region belongs to the active app's menus, and items
        // never cross over into it. A display without a notch returns nil here and the
        // check is skipped.
        if let usableArea = screen.auxiliaryTopRightArea, usableArea.width > 0, frame.width > 0 {
            // Horizontal overlap only. Whether the notch is in the way is a question
            // about x — using NSRect.intersection required both axes to overlap, and the
            // status item's window does not share a y range with this area, so the
            // intersection came back empty for items sitting in plain sight.
            let visibleWidth = min(usableArea.maxX, frame.maxX) - max(usableArea.minX, frame.minX)
            if visibleWidth <= 0 { return .hiddenByNotch }
            if visibleWidth < frame.width - 1 { return .clippedByNotch }
        }
        return .onScreen
    }

    enum MenuBarPlacement: Sendable, Equatable {
        case disabled
        /// The provider is enabled and drawn inside the shared status item.
        case combined
        case hiddenByUser
        case notPlacedYet
        case onScreen
        /// Created, visible, but nowhere a person can see it — almost always a menu bar
        /// with no space left.
        case noRoom
        /// Pushed entirely behind the notch.
        case hiddenByNotch
        /// Partly behind the notch: some of it shows, the rest is cut off.
        case clippedByNotch

        var displayName: String {
            displayName(language: .english)
        }

        func displayName(language: AppLanguage) -> String {
            switch self {
            case .disabled: language.text(chinese: "未啟用", english: "Disabled")
            case .combined: language.text(chinese: "顯示於合併圖示", english: "In combined icon")
            case .hiddenByUser: language.text(chinese: "已隱藏", english: "Hidden")
            case .notPlacedYet: language.text(chinese: "尚未放置", english: "Not placed yet")
            case .onScreen: language.text(chinese: "顯示於獨立圖示", english: "In separate icon")
            case .noRoom: language.text(chinese: "選單列空間不足", english: "No room in menu bar")
            case .hiddenByNotch: language.text(chinese: "被瀏海完全遮住", english: "Hidden behind the notch")
            case .clippedByNotch: language.text(chinese: "部分被瀏海遮住", english: "Partially obscured by the notch")
            }
        }

        var isDisplayed: Bool {
            self == .combined || self == .onScreen
        }

        var explanation: String? {
            explanation(language: .english)
        }

        func explanation(language: AppLanguage) -> String? {
            switch self {
            case .noRoom:
                language.text(
                    chinese: "圖示已建立，但 macOS 沒有空間顯示。請關閉幾個其他選單列 App，或使用 Bartender 等工具整理。瀏海機型實際可用空間比看起來少。",
                    english: "The icon exists, but macOS has no room to display it. Close a few other menu bar apps, or organize them with a tool such as Bartender. Notched Macs have less usable space than they appear to."
                )
            case .hiddenByUser:
                language.text(
                    chinese: "macOS 將這個圖示標記為隱藏。把上方開關關掉再打開即可重設。",
                    english: "macOS marked this icon as hidden. Turn the switch above off and back on to reset it."
                )
            case .hiddenByNotch, .clippedByNotch:
                language.text(
                    chinese: "圖示被擠到瀏海後面了。請關閉幾個其他選單列 App 騰出空間。App 圖示只能使用瀏海左側；右側由系統保留。",
                    english: "The icon was pushed behind the notch. Close a few other menu bar apps to make room. App icons can only use the area left of the notch; the area on the right is reserved by the system."
                )
            default:
                nil
            }
        }
    }

    /// Tears everything down and rebuilds. Used when the layout changes, where an
    /// incremental update would have to reason about two shapes at once.
    private func rebuildItems() {
        for (provider, item) in providerItems {
            NSStatusBar.system.removeStatusItem(item)
            popovers[provider]?.performClose(nil)
            popovers[provider] = nil
        }
        providerItems.removeAll()
        if let combinedItem {
            NSStatusBar.system.removeStatusItem(combinedItem)
            self.combinedItem = nil
        }
        combinedPopover?.performClose(nil)
        combinedPopover = nil
        synchronize()
    }

    /// Creates and tears down items to match the current settings.
    func synchronize() {
        let combining = model.menuBarLayout == .combined && !model.allProvidersDisabled

        if combining {
            for (provider, item) in providerItems {
                NSStatusBar.system.removeStatusItem(item)
                popovers[provider]?.performClose(nil)
                popovers[provider] = nil
            }
            providerItems.removeAll()
            if combinedItem == nil { combinedItem = makeCombinedItem() }
        } else {
            if let combinedItem {
                NSStatusBar.system.removeStatusItem(combinedItem)
                self.combinedItem = nil
                combinedPopover?.performClose(nil)
                combinedPopover = nil
            }
            for presenter in model.presenters {
                if presenter.settings.isEnabled {
                    if providerItems[presenter.provider] == nil {
                        providerItems[presenter.provider] = makeItem(for: presenter)
                    }
                } else if let item = providerItems.removeValue(forKey: presenter.provider) {
                    NSStatusBar.system.removeStatusItem(item)
                    popovers[presenter.provider]?.performClose(nil)
                    popovers[presenter.provider] = nil
                }
            }
        }

        if model.allProvidersDisabled {
            if neutralItem == nil { neutralItem = makeNeutralItem() }
        } else if let item = neutralItem {
            NSStatusBar.system.removeStatusItem(item)
            neutralItem = nil
        }

        updateImages()
    }

    private func makeCombinedItem() -> NSStatusItem {
        let count = max(1, model.enabledPresenters.count)
        let item = NSStatusBar.system.statusItem(withLength: GaugeImageRenderer.combinedWidth(count: count))
        item.autosaveName = "AgentUsageBar.combined"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(combinedItemClicked(_:))
        item.button?.imagePosition = .imageOnly
        return item
    }

    /// The combined icon stands for every enabled provider, so clicking it shows every
    /// enabled provider.
    ///
    /// An earlier version picked one — ranked by "most in need of attention" — which
    /// meant an unimplemented provider, permanently in need of attention, won every
    /// time and the working provider's readings could not be reached at all.
    @objc private func combinedItemClicked(_ sender: NSStatusBarButton) {
        let presenters = model.enabledPresenters
        guard !presenters.isEmpty else { return }
        toggleCombinedPopover(for: presenters, relativeTo: sender)
    }

    private func toggleCombinedPopover(for presenters: [ProviderPresenter], relativeTo button: NSStatusBarButton) {
        let popover = combinedPopover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            combinedPopover = popover
            return popover
        }()

        if popover.isShown {
            popover.performClose(nil)
        } else {
            configurePopover(popover, presenters: presenters, relativeTo: button) { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.onOpenSettings()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func makeItem(for presenter: ProviderPresenter) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: GaugeImageRenderer.size.width + 8)
        // Distinct autosave names are not optional with more than one item. AppKit
        // derives a name from the app when none is given, so two items end up sharing
        // one persisted position and visibility record — and the second one to claim it
        // can land on top of the first or not appear at all.
        item.autosaveName = "AgentUsageBar.\(presenter.provider.rawValue)"
        // The in-app toggle is the authority on whether this gauge exists. Without this,
        // a visibility flag persisted from an earlier run can leave the item switched on
        // in Settings but absent from the menu bar, with nothing to explain the gap.
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.identifier = NSUserInterfaceItemIdentifier(presenter.provider.rawValue)
        item.button?.imagePosition = .imageOnly
        return item
    }

    private func makeNeutralItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        item.autosaveName = "AgentUsageBar.neutral"
        item.isVisible = true
        item.button?.image = GaugeImageRenderer.neutralAppIcon()
        item.button?.target = self
        item.button?.action = #selector(neutralItemClicked(_:))
        updateNeutralItemCopy(item)
        return item
    }

    private func updateNeutralItemCopy(_ item: NSStatusItem) {
        let language = model.displayLanguage
        item.button?.setAccessibilityLabel(language.text(
            chinese: "Agent Usage Bar，所有供應商皆已停用，按一下開啟設定",
            english: "Agent Usage Bar, all providers disabled, click to open Settings"
        ))
        item.button?.toolTip = language.text(
            chinese: "所有供應商皆已停用。按一下即可重新啟用。",
            english: "All providers are disabled. Click to re-enable them."
        )
    }

    func languageDidChange() {
        combinedPopover?.performClose(nil)
        for popover in popovers.values { popover.performClose(nil) }
        if let neutralItem { updateNeutralItemCopy(neutralItem) }
        updateImages()
    }

    private func updateImages() {
        if let combinedItem, let button = combinedItem.button {
            let entries = model.enabledPresenters.map { presenter in
                (model: presenter.renderModel(locale: model.displayLanguage.locale), identityColor: presenter.settings.identityColor.nsColor)
            }
            combinedItem.length = GaugeImageRenderer.combinedWidth(count: max(1, entries.count))
            button.image = GaugeImageRenderer.combinedImage(for: entries)
            let separator = model.displayLanguage == .traditionalChinese ? "；" : "; "
            let label = entries.map(\.model.accessibilityLabel).joined(separator: separator)
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }

        for presenter in model.presenters {
            guard let button = providerItems[presenter.provider]?.button else { continue }
            let renderModel = presenter.renderModel(locale: model.displayLanguage.locale)
            button.image = GaugeImageRenderer.image(
                for: renderModel,
                identityColor: presenter.settings.identityColor.nsColor
            )
            // Colour is never the only carrier: the glyph is in the image and the full
            // reading is in the accessibility label and the tooltip.
            button.setAccessibilityLabel(renderModel.accessibilityLabel)
            button.toolTip = renderModel.accessibilityLabel
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue,
              let provider = ProviderKind(rawValue: raw),
              let presenter = model.presenter(for: provider)
        else { return }
        togglePopover(for: presenter, relativeTo: sender)
    }

    /// The neutral item exists only because every provider is switched off. Showing a
    /// provider's readings behind it would be showing data the user asked not to see —
    /// its whole job is to be the way back into Settings.
    @objc private func neutralItemClicked(_ sender: NSStatusBarButton) {
        onOpenSettings()
    }

    private func togglePopover(for presenter: ProviderPresenter, relativeTo button: NSStatusBarButton) {
        let popover = popovers[presenter.provider] ?? makePopover()
        popovers[presenter.provider] = popover
        if popover.isShown {
            popover.performClose(nil)
        } else {
            configurePopover(popover, presenters: [presenter], relativeTo: button) { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.onOpenSettings()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        return popover
    }

    private func configurePopover(
        _ popover: NSPopover,
        presenters: [ProviderPresenter],
        relativeTo button: NSStatusBarButton,
        onOpenSettings: @escaping () -> Void
    ) {
        let naturalController = NSHostingController(
            rootView: UsagePopoverView(
                presenters: presenters,
                language: model.displayLanguage,
                allowsScrolling: false,
                onOpenSettings: onOpenSettings
            )
        )
        let desired = naturalController.sizeThatFits(
            in: NSSize(width: 320, height: 10_000)
        ).height
        let available = button.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 700
        let layout = Self.popoverLayout(desiredHeight: desired, availableHeight: available)

        if layout.usesScrolling {
            popover.contentViewController = NSHostingController(
                rootView: UsagePopoverView(
                    presenters: presenters,
                    language: model.displayLanguage,
                    allowsScrolling: true,
                    onOpenSettings: onOpenSettings
                )
            )
        } else {
            popover.contentViewController = naturalController
        }
        popover.contentSize = NSSize(width: 320, height: layout.height)
    }
}
