import Foundation

/// Which usage rows the panel shows folded to a single line.
///
/// # Why this exists
///
/// The number of windows is not fixed: five hours, seven days, and any number of
/// per-model weekly limits. Three full rows for one provider make the panel long, and
/// the person looking at it knows which of them matter today.
///
/// # What a folded row still shows
///
/// Its name, its percentage, and the binding badge. Folding hides the bar and the reset
/// time; it never hides the figure. That is what makes it safe to remember across
/// launches with no rule that unfolds a row once it gets urgent.
///
/// # Defaults
///
/// The session window and the all-models weekly window start unfolded: they are the two
/// every account has. A row scoped to one model starts folded. A kind this build has
/// never seen starts unfolded, because the first time a new limit appears it should be
/// seen whole.
///
/// Only departures from the default are kept, so a row never seen before behaves
/// according to its kind rather than to a leftover entry.
public struct WindowDisclosure: Sendable, Equatable {

    /// A bound, not a policy. Keys embed provider-supplied labels, and labels change as
    /// models come and go; without a cap a long-lived install would keep one entry for
    /// every label it had ever folded.
    public static let maximumOverrides = 64

    /// `true` means folded. Only entries that differ from the default are present.
    public private(set) var overrides: [String: Bool]

    public init() {
        overrides = [:]
    }

    /// Restores a stored preference. Anything other than a bounded dictionary of safe
    /// keys is treated as no preference at all rather than repaired entry by entry.
    public init(storedValue: Any?) {
        guard let stored = storedValue as? [String: Bool],
              stored.count <= Self.maximumOverrides,
              stored.keys.allSatisfy(Self.isStorable) else {
            overrides = [:]
            return
        }
        overrides = stored
    }

    public var storedValue: [String: Bool] { overrides }

    public static func isCollapsedByDefault(_ window: UsageWindow) -> Bool {
        if case .weeklyScoped = window.kind { return true }
        return false
    }

    public func isCollapsed(_ window: UsageWindow, provider: ProviderKind) -> Bool {
        overrides[Self.key(window, provider: provider)] ?? Self.isCollapsedByDefault(window)
    }

    public mutating func toggle(_ window: UsageWindow, provider: ProviderKind) {
        let key = Self.key(window, provider: provider)
        // A row whose identity cannot be stored safely keeps its default. Toggling it
        // for the life of one panel and forgetting it on the next would be worse.
        guard Self.isStorable(key) else { return }

        let collapsed = !isCollapsed(window, provider: provider)
        guard collapsed != Self.isCollapsedByDefault(window) else {
            overrides[key] = nil
            return
        }
        if overrides[key] == nil, overrides.count >= Self.maximumOverrides,
           let evicted = overrides.keys.sorted().first {
            // Which entry goes is arbitrary but deterministic. Reaching the cap takes
            // dozens of distinct rows, so the choice is not worth a recency record.
            overrides[evicted] = nil
        }
        overrides[key] = collapsed
    }

    /// The provider is part of the key because both providers have a session window and
    /// a weekly window, and folding one must not fold the other's.
    static func key(_ window: UsageWindow, provider: ProviderKind) -> String {
        "\(provider.rawValue)/\(window.id)"
    }

    /// Window identity includes a provider-supplied label, so a key passes the same
    /// bound as any other provider text before it is written to preferences.
    private static func isStorable(_ key: String) -> Bool {
        !key.isEmpty && ProviderMetadataText.isSafeDisplay(key)
    }
}
