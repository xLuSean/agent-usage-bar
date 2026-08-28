import AppKit
import UsageMeterCore

/// User-selectable outline colour. A fixed palette rather than a free colour picker,
/// so two providers cannot be set to shades nobody can tell apart.
///
/// Every entry avoids green, orange, and red: those are reserved for the fill, which
/// carries severity. An outline that can turn orange would collide with the one thing
/// the fill is there to say.
enum IdentityColor: String, CaseIterable, Sendable, Identifiable {
    case purple, teal, blue, pink, indigo, graphite

    var id: String { rawValue }

    var displayName: String {
        displayName(language: .english)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .purple: language.text(chinese: "紫", english: "Purple")
        case .teal: language.text(chinese: "青", english: "Teal")
        case .blue: language.text(chinese: "藍", english: "Blue")
        case .pink: language.text(chinese: "粉紅", english: "Pink")
        case .indigo: language.text(chinese: "靛", english: "Indigo")
        case .graphite: language.text(chinese: "石墨", english: "Graphite")
        }
    }

    var nsColor: NSColor {
        switch self {
        case .purple: .systemPurple
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .pink: .systemPink
        case .indigo: .systemIndigo
        case .graphite: .secondaryLabelColor
        }
    }
}

extension GaugeFillLevel {
    /// Severity colours. Not customisable — this is the channel that has to keep
    /// meaning the same thing across both providers.
    ///
    /// Orange rather than yellow for `caution`: yellow at this size disappears against
    /// a light menu bar.
    var fillColor: NSColor {
        switch self {
        case .ok: .systemGreen
        case .caution: .systemOrange
        case .critical: .systemRed
        case .exhausted: .systemRed
        case .unknown: .tertiaryLabelColor
        }
    }

    var displayName: String {
        displayName(language: .english)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .ok: language.text(chinese: "用量正常", english: "Usage normal")
        case .caution: language.text(chinese: "用量偏高", english: "Usage elevated")
        case .critical: language.text(chinese: "接近上限", english: "Near limit")
        case .exhausted: language.text(chinese: "已耗盡", english: "Exhausted")
        case .unknown: language.text(chinese: "未知", english: "Unknown")
        }
    }
}
