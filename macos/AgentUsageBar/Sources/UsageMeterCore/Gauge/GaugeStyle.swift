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

public struct GaugeWindowRenderModel: Sendable, Hashable {
    public enum Availability: Sendable, Hashable {
        case reported
        case notListed
        case unknown
    }

    public let fillLevel: GaugeFillLevel
    public let frameStyle: GaugeFrameStyle
    public let fillFraction: Double
    public let availability: Availability
}

/// One provider, one shared frame, two fixed slots. Neither slot falls back to the
/// other quota or to a model-scoped weekly meter.
public struct GaugeRenderModel: Sendable, Hashable {
    public let provider: ProviderKind
    public let session: GaugeWindowRenderModel
    public let weekly: GaugeWindowRenderModel
    public let frameStyle: GaugeFrameStyle
    public var glyph: String { provider.identityLetter }
    public let accessibilityLabel: String

    public init(
        provider: ProviderKind,
        session: GaugeWindowRenderModel,
        weekly: GaugeWindowRenderModel,
        frameStyle: GaugeFrameStyle,
        accessibilityLabel: String
    ) {
        self.provider = provider
        self.session = session
        self.weekly = weekly
        self.frameStyle = frameStyle
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
        let frameStyle = frameStyle(for: state)
        func segment(_ kind: UsageWindow.Kind) -> GaugeWindowRenderModel {
            guard let window = state.snapshot?.quotaWindow(for: kind) else {
                let notListed = state.snapshot?.isQuotaNotListed(kind) == true
                return GaugeWindowRenderModel(
                    fillLevel: .unknown,
                    frameStyle: notListed ? .disabledNeutral : .dashedEmpty,
                    fillFraction: 0,
                    availability: notListed ? .notListed : .unknown
                )
            }
            let expired = window.hasExpired(at: now)
            return GaugeWindowRenderModel(
                fillLevel: fillLevel(for: window),
                frameStyle: frameStyle == .solid && expired ? .staleMarked : frameStyle,
                fillFraction: window.used.usedFraction,
                availability: .reported
            )
        }
        return GaugeRenderModel(
            provider: provider,
            session: segment(.session),
            weekly: segment(.weeklyAll),
            frameStyle: frameStyle,
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
        let chinese = TimeFormatting.usesTraditionalChinese(locale)
        let readings = [UsageWindow.Kind.session, .weeklyAll].map { kind in
            let title = kind == .session ? (chinese ? "5 小時" : "5 hours") : (chinese ? "7 天" : "7 days")
            guard let window = state.snapshot?.quotaWindow(for: kind) else {
                if state.snapshot?.isQuotaNotListed(kind) == true {
                    return chinese ? "\(title)未列出此限制" : "\(title): no limit listed by the service"
                }
                return chinese ? "\(title)額度未知（尚未提供）" : "\(title): usage unknown (not reported)"
            }
            let reading = chinese
                ? "\(title)額度已用約 \(window.used.usedPercent)%，剩餘約 \(window.used.remainingPercent)%"
                : "\(title), approximately \(window.used.usedPercent)% used, \(window.used.remainingPercent)% remaining"
            if window.hasExpired(at: now) {
                return reading + (chinese ? "（已過重設時間，等待更新）" : " (past reset, waiting for an update)")
            }
            return reading
        }
        let usage = ([provider.displayName] + readings).joined(separator: chinese ? "；" : "; ")
        if chinese {
            switch state {
            case .current:
                return "\(usage)，最近查詢成功"
            case .refreshing:
                return "\(usage)，正在更新"
            case .starting:
                return "\(usage)，啟動中"
            case .stale(let snapshot, let reason):
                let time = TimeFormatting.timeOfDay(snapshot.fetchedAt, locale: locale)
                return "\(usage)，資料過期，最後更新於 \(time)，原因：\(reason.shortDescription(locale: locale))"
            case .throttled(_, let until):
                return "\(usage)，已被限流，預計 \(TimeFormatting.relative(from: now, to: until, locale: locale)) 後恢復"
            case .unavailable(let error):
                return "\(usage)，\(error.shortDescription(locale: locale))"
            }
        }
        switch state {
        case .current:
            return "\(usage), last query succeeded"
        case .refreshing:
            return "\(usage), refreshing"
        case .starting:
            return "\(usage), starting"
        case .stale(let snapshot, let reason):
            let time = TimeFormatting.timeOfDay(snapshot.fetchedAt, locale: locale)
            return "\(usage), stale data last updated at \(time), reason: \(reason.shortDescription(locale: locale))"
        case .throttled(_, let until):
            return "\(usage), rate limited, expected to recover in \(TimeFormatting.relative(from: now, to: until, locale: locale))"
        case .unavailable(let error):
            return "\(usage), \(error.shortDescription(locale: locale))"
        }
    }
}
