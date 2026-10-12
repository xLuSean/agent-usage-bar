import Observation
import UsageMeterCore

/// The panel's folded rows: one copy for every popover, remembered across launches.
///
/// This is the one piece of state the popover changes itself. Everything else that can
/// be changed lives in the settings window, because a transient popover closes as soon
/// as focus moves and is a bad place to change something and then look at the result.
/// Folding a row is different: the result is the popover.
///
/// It is observable so that folding a row re-renders the popover that is already open,
/// rather than taking effect the next time one is built.
@MainActor
@Observable
final class WindowDisclosureModel {
    private(set) var disclosure: WindowDisclosure
    private let persist: (WindowDisclosure) -> Void

    /// The default arguments give a model that remembers nothing, for render checks.
    init(
        disclosure: WindowDisclosure = WindowDisclosure(),
        persist: @escaping (WindowDisclosure) -> Void = { _ in }
    ) {
        self.disclosure = disclosure
        self.persist = persist
    }

    func isCollapsed(_ window: UsageWindow, provider: ProviderKind) -> Bool {
        disclosure.isCollapsed(window, provider: provider)
    }

    func toggle(_ window: UsageWindow, provider: ProviderKind) {
        let previous = disclosure
        disclosure.toggle(window, provider: provider)
        guard disclosure != previous else { return }
        persist(disclosure)
    }
}
