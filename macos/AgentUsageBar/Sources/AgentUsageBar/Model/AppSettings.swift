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

/// How much of Codex's provider-maintained daily account history is drawn in the
/// popover. This is a display preference only; the latest snapshot still retains the
/// complete bounded response so changing the range never requires another provider
/// read and never destroys upstream data.
enum CodexTokenHistoryPeriod: Int, CaseIterable, Sendable, Identifiable {
    case fiveDays = 5
    case tenDays = 10
    case fifteenDays = 15
    case twentyDays = 20
    case thirtyDays = 30
    case sixtyDays = 60

    var id: Int { rawValue }
}

/// Codex account token statistics move more slowly than quota windows and are returned
/// as one history payload. Give that read its own user-controlled cadence without
/// changing the existing quota refresh choices.
enum CodexTokenRefreshInterval: Int, CaseIterable, Sendable, Identifiable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case threeHours = 10_800
    case sixHours = 21_600

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    static let recommended = CodexTokenRefreshInterval.oneHour

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .fifteenMinutes:
            language.text(chinese: "15 分鐘", english: "15 minutes")
        case .thirtyMinutes:
            language.text(chinese: "30 分鐘", english: "30 minutes")
        case .oneHour:
            language.text(chinese: "1 小時", english: "1 hour")
        case .twoHours:
            language.text(chinese: "2 小時", english: "2 hours")
        case .threeHours:
            language.text(chinese: "3 小時", english: "3 hours")
        case .sixHours:
            language.text(chinese: "6 小時", english: "6 hours")
        }
    }

    var refreshesPerDay: Int { Int((24 * 60 * 60) / seconds) }
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
    private static let codexTokenHistoryDaysKey = "\(version).codexTokenHistoryDays"
    private static let codexTokenRefreshIntervalKey = "\(version).codexTokenRefreshInterval"

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

    static func loadCodexTokenHistoryPeriod(
        defaults: UserDefaults = .standard
    ) -> CodexTokenHistoryPeriod {
        let raw = defaults.object(forKey: codexTokenHistoryDaysKey) as? Int
        return raw.flatMap(CodexTokenHistoryPeriod.init(rawValue:)) ?? .thirtyDays
    }

    static func saveCodexTokenHistoryPeriod(
        _ period: CodexTokenHistoryPeriod,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(period.rawValue, forKey: codexTokenHistoryDaysKey)
    }

    static func loadCodexTokenRefreshInterval(
        defaults: UserDefaults = .standard
    ) -> CodexTokenRefreshInterval {
        let raw = defaults.object(forKey: codexTokenRefreshIntervalKey) as? Int
        return raw.flatMap(CodexTokenRefreshInterval.init(rawValue:)) ?? .recommended
    }

    static func saveCodexTokenRefreshInterval(
        _ interval: CodexTokenRefreshInterval,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(interval.rawValue, forKey: codexTokenRefreshIntervalKey)
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
