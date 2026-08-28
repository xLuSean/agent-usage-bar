import Foundation
import UsageMeterCore

/// Per-provider preferences. Keys are versioned so a later layout change can be
/// migrated rather than silently misread.
struct ProviderSettings: Sendable, Equatable {
    var isEnabled: Bool
    var identityColor: IdentityColor
    var refreshInterval: RefreshInterval
}

/// The language selected inside the app. This is deliberately independent from the
/// system language so the user can switch without restarting macOS or the app.
enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale {
        switch self {
        case .traditionalChinese: Locale(identifier: "zh_Hant_TW")
        case .english: Locale(identifier: "en_US")
        }
    }

    /// Language names stay in their own language so both choices remain recognizable.
    var displayName: String {
        switch self {
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        }
    }

    func text(chinese: String, english: String) -> String {
        self == .traditionalChinese ? chinese : english
    }

}

/// How the gauges are laid out in the menu bar.
enum MenuBarLayout: String, CaseIterable, Sendable, Identifiable {
    /// One `NSStatusItem` per provider, side by side.
    case separate
    /// Both gauges drawn inside a single `NSStatusItem`.
    ///
    /// Exists because menu bar space is finite in a way macOS never tells you about:
    /// on a notched Mac, items that do not fit beside the notch are simply not drawn,
    /// with no notification and no error. Halving the footprint is sometimes the only
    /// way to see both.
    case combined

    var id: String { rawValue }

    var displayName: String {
        displayName(language: .english)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .separate: language.text(chinese: "分開顯示（兩個圖示）", english: "Separate (two icons)")
        case .combined: language.text(chinese: "合併顯示（一個圖示）", english: "Combined (one icon)")
        }
    }
}

enum SettingsStore {
    private static let version = "v1"

    private static func key(_ provider: ProviderKind, _ name: String) -> String {
        "\(version).provider.\(provider.rawValue).\(name)"
    }

    static func load(_ provider: ProviderKind, defaults: UserDefaults = .standard) -> ProviderSettings {
        let isEnabled = defaults.object(forKey: key(provider, "enabled")) as? Bool ?? defaultEnabled(for: provider)
        let colorRaw = defaults.string(forKey: key(provider, "identityColor"))
        let intervalRaw = defaults.object(forKey: key(provider, "refreshInterval")) as? Int
        return ProviderSettings(
            isEnabled: isEnabled,
            identityColor: colorRaw.flatMap(IdentityColor.init(rawValue:)) ?? defaultColor(for: provider),
            refreshInterval: intervalRaw.flatMap(RefreshInterval.init(rawValue:)) ?? defaultRefreshInterval(for: provider)
        )
    }

    static func save(_ settings: ProviderSettings, for provider: ProviderKind, defaults: UserDefaults = .standard) {
        defaults.set(settings.isEnabled, forKey: key(provider, "enabled"))
        defaults.set(settings.identityColor.rawValue, forKey: key(provider, "identityColor"))
        defaults.set(settings.refreshInterval.rawValue, forKey: key(provider, "refreshInterval"))
    }

    private static let layoutKey = "\(version).menuBarLayout"
    private static let languageKey = "\(version).displayLanguage"
    private static let claudeExecutablePathKey = "\(version).claudeExecutablePath"
    private static let codexExecutablePathKey = "\(version).codexExecutablePath"

    /// Blank means auto-detect. A GUI app's PATH is not the shell's, so an unusual
    /// install location has to be nameable.
    static func loadClaudeExecutablePath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: claudeExecutablePathKey) ?? ""
    }

    static func saveClaudeExecutablePath(_ path: String, defaults: UserDefaults = .standard) {
        defaults.set(path, forKey: claudeExecutablePathKey)
    }

    static func loadLayout(defaults: UserDefaults = .standard) -> MenuBarLayout {
        defaults.string(forKey: layoutKey).flatMap(MenuBarLayout.init(rawValue:)) ?? .separate
    }

    static func saveLayout(_ layout: MenuBarLayout, defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValue, forKey: layoutKey)
    }

    static func loadLanguage(defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .traditionalChinese
    }

    static func saveLanguage(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: languageKey)
    }

    static func loadCodexExecutablePath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: codexExecutablePathKey) ?? ""
    }

    static func saveCodexExecutablePath(_ path: String, defaults: UserDefaults = .standard) {
        defaults.set(path, forKey: codexExecutablePathKey)
    }

    static func defaultEnabled(for provider: ProviderKind) -> Bool {
        switch provider {
        case .claude: true
        case .codex: true
        }
    }

    static func defaultRefreshInterval(for provider: ProviderKind) -> RefreshInterval {
        RefreshInterval.recommended(for: provider)
    }

    static func defaultColor(for provider: ProviderKind) -> IdentityColor {
        switch provider {
        case .claude: .purple
        case .codex: .teal
        }
    }
}
