import Foundation

/// The gauge's visual vocabulary. This is the one layer the plans make
/// non-negotiable across providers, so it lives in shared code and is described
/// in semantic terms — no AppKit types, no per-provider branches.
///
/// Division of labour:
///   outline colour → identity (which provider), user-customisable
///   fill colour    → usage level (how close to exhausted), not customisable
///   fill height    → **consumed** proportion — the gauge fills up as quota is spent
///   glyph          → identity again, as a cue that does not depend on colour
public enum GaugeFillLevel: Sendable, Hashable {
    /// Comfortable headroom.
    case ok
    /// Getting low.
    case caution
    /// Nearly gone.
    case critical
    /// Exactly 100% used. Drawn with an explicit exhausted mark, not as a full bar,
    /// so "nothing left" cannot be mistaken for "plenty left".
    case exhausted
    /// No trustworthy reading. Must never be drawn as 0% — empty and unknown are
    /// different facts and have to look different.
    case unknown
}

/// How the frame is drawn, carrying data trustworthiness rather than quantity.
public enum GaugeFrameStyle: Sendable, Hashable {
    case solid
    /// Reduced saturation plus a warning mark: a real reading, known to be old.
    case staleMarked
    /// Striped fill: rate limited, recovery time known.
    case throttledStriped
    /// Dashed outline, no fill: nothing trustworthy to show.
    case dashedEmpty
    /// Neutral. The user switched this provider off; not a problem to report.
    case disabledNeutral
}

public struct GaugeRenderModel: Sendable, Hashable {
    public let provider: ProviderKind
    public let fillLevel: GaugeFillLevel
    public let frameStyle: GaugeFrameStyle
    /// 0…1 of the inner height. Zero when there is nothing trustworthy to fill with.
    public let fillFraction: Double
    /// Drawn inside/next to the frame as the non-colour identity cue.
    public let glyph: String
    public let accessibilityLabel: String

    public init(
        provider: ProviderKind,
        fillLevel: GaugeFillLevel,
        frameStyle: GaugeFrameStyle,
        fillFraction: Double,
        glyph: String,
        accessibilityLabel: String
    ) {
        self.provider = provider
        self.fillLevel = fillLevel
        self.frameStyle = frameStyle
        self.fillFraction = fillFraction
        self.glyph = glyph
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum GaugeStyleResolver {

    /// Thresholds on *used* percent. These are the only input to the fill colour, for
    /// every provider.
    ///
    /// # Why not each vendor's own severity verdict
    ///
    /// The Claude response carries a `severity` field, and an earlier design preferred
    /// it. Codex will have some equivalent, graded by whatever Codex considers
    /// concerning — which is not the same line Anthropic draws.
    ///
    /// Deferring to each vendor means the same colour stops meaning the same thing:
    /// orange on one gauge and orange on the gauge beside it would answer different
    /// questions, and the user would have to hold two scales in their head to read one
    /// menu bar. That defeats the point of the two gauges sharing a visual language at
    /// all. It also showed up immediately in practice — a window at 58% consumed drew
    /// green because the server called it "normal", while the label beside it read 58%.
    ///
    /// So one scale, applied to the number, for both providers. A provider's raw limit
    /// status may be shown separately, but it is not duplicated on every window.
    ///
    /// **This binds the Codex provider too** — see docs/UI_SPEC.md §3.
    public static func localFillLevel(usedPercent: Int) -> GaugeFillLevel {
        switch usedPercent {
        case 100...: .exhausted
        case 80..<100: .critical
        case 50..<80: .caution
        default: .ok
        }
    }

    /// The fill level for a window. Derived from the consumed percentage and nothing
    /// else, so the colour is always predictable from the number beside it.
    public static func fillLevel(for window: UsageWindow?) -> GaugeFillLevel {
        guard let window else { return .unknown }
        return localFillLevel(usedPercent: window.used.usedPercent)
    }

    public static func frameStyle(for state: UsageDisplayState) -> GaugeFrameStyle {
        switch state {
        case .current: .solid
        case .refreshing(let previous): previous == nil ? .dashedEmpty : .solid
        case .starting: .dashedEmpty
        case .stale: .staleMarked
        case .throttled: .throttledStriped
        case .unavailable: .dashedEmpty
        }
    }

    public static func renderModel(
        provider: ProviderKind,
        state: UsageDisplayState,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "en_US")
    ) -> GaugeRenderModel {
        let window = state.snapshot?.representativeWindow
        let frameStyle = frameStyle(for: state)
        let level: GaugeFillLevel = {
            // A dashed-empty frame means there is nothing to trust; drawing a fill
            // would be the "pretend unknown is 0%" mistake in a different shade.
            if frameStyle == .dashedEmpty { return .unknown }
            return fillLevel(for: window)
        }()
        let fraction: Double = level == .unknown ? 0 : (window?.used.usedFraction ?? 0)
        return GaugeRenderModel(
            provider: provider,
            fillLevel: level,
            frameStyle: frameStyle,
            fillFraction: fraction,
            glyph: provider.identityLetter,
            accessibilityLabel: accessibilityLabel(
                provider: provider, state: state, now: now, locale: locale
            )
        )
    }

    /// VoiceOver text. Required, not optional: a gauge whose only output is a drawn
    /// bar tells a screen-reader user nothing.
    public static func accessibilityLabel(
        provider: ProviderKind,
        state: UsageDisplayState,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        let name = provider.displayName
        if TimeFormatting.usesTraditionalChinese(locale) {
            guard let window = state.snapshot?.representativeWindow else {
                let reason = state.error?.shortDescription(locale: locale)
                    ?? state.statusLabel(locale: locale)
                return "\(name) 額度未知，\(reason)"
            }
            let usage = "\(name) \(window.displayName(locale: locale))額度已用約 \(window.used.usedPercent)%"
            switch state {
            case .current:
                return "\(usage)，資料為最新"
            case .refreshing:
                return "\(usage)，正在更新"
            case .starting:
                return "\(name) 額度未知，啟動中"
            case .stale(let snapshot, let reason):
                let time = TimeFormatting.timeOfDay(snapshot.fetchedAt, locale: locale)
                return "\(usage)，資料過期，最後更新於 \(time)，原因：\(reason.shortDescription(locale: locale))"
            case .throttled(_, let until):
                return "\(usage)，已被限流，預計 \(TimeFormatting.relative(from: now, to: until, locale: locale)) 後恢復"
            case .unavailable(let error):
                return "\(name) 額度不可用，\(error.shortDescription(locale: locale))"
            }
        }
        guard let window = state.snapshot?.representativeWindow else {
            let reason = state.error?.shortDescription(locale: locale) ?? state.statusLabel(locale: locale)
            return "\(name) usage unknown: \(reason)"
        }
        let usage = "\(name), \(window.displayName(locale: locale)), approximately \(window.used.usedPercent)% used"
        switch state {
        case .current:
            return "\(usage), data is current"
        case .refreshing:
            return "\(usage), refreshing"
        case .starting:
            return "\(name) usage unknown, starting"
        case .stale(let snapshot, let reason):
            let time = TimeFormatting.timeOfDay(snapshot.fetchedAt, locale: locale)
            return "\(usage), stale data last updated at \(time), reason: \(reason.shortDescription(locale: locale))"
        case .throttled(_, let until):
            return "\(usage), rate limited, expected to recover in \(TimeFormatting.relative(from: now, to: until, locale: locale))"
        case .unavailable(let error):
            return "\(name) usage unavailable: \(error.shortDescription(locale: locale))"
        }
    }
}
