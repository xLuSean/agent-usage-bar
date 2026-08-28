import Foundation

/// A usage figure with its original scale attached.
///
/// The two Claude data paths express "how much is used" on different scales and the
/// names collide: the usage endpoint's `percent` is a 0–100 integer, while the
/// `/v1/messages` fallback header `utilization` is a 0–1 fraction. Letting both flow
/// through a bare `Double` is how a 29% reading becomes a 0.29% reading.
///
/// The endpoint that carried the 0–1 form is retired, but the type stays: the trap is
/// about two same-named fields on different scales, and the next source to appear can
/// reintroduce it. See `docs/LEGACY_KEYCHAIN_PATH.md` §3.5.
public struct UsedPercent: Sendable, Hashable, Codable {

    private enum CodingKeys: String, CodingKey {
        case normalized
        case originalScale
    }

    public enum Scale: String, Sendable, Hashable, Codable {
        /// `limits[].percent` from `GET /api/oauth/usage`.
        case hundred
        /// `anthropic-ratelimit-unified-*-utilization` response headers.
        case unit
    }

    /// Always normalized to the 0–100 scale, clamped, never rounded.
    public let normalized: Double
    /// Which scale the value arrived on. Diagnostics only.
    public let originalScale: Scale

    /// Restores a value that was already normalized, for decoding. Not a third scale.
    public init(normalized: Double, originalScale: Scale) {
        self.normalized = Self.clamp(normalized)
        self.originalScale = originalScale
    }

    public init(hundredScale raw: Double) {
        self.normalized = Self.clamp(raw)
        self.originalScale = .hundred
    }

    /// `raw * 100` is where `0.29` turns into `28.999999999999996`.
    /// Nothing here rounds; `usedPercent` does, once, at the display boundary.
    public init(unitScale raw: Double) {
        self.normalized = Self.clamp(raw * 100)
        self.originalScale = .unit
    }

    /// Persisted JSON is a trust boundary. Synthesized `Decodable` would assign the
    /// stored value directly and bypass every public initializer, allowing a damaged
    /// cache to restore 250% as if it were a valid domain value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let normalized = try container.decode(Double.self, forKey: .normalized)
        guard normalized.isFinite, (0...100).contains(normalized) else {
            throw DecodingError.dataCorruptedError(
                forKey: .normalized,
                in: container,
                debugDescription: "Persisted usage percentage must be finite and between 0 and 100"
            )
        }
        self.normalized = normalized
        self.originalScale = try container.decode(Scale.self, forKey: .originalScale)
    }

    /// Whole-percent used figure. The single rounding point in the pipeline.
    public var usedPercent: Int { Int(normalized.rounded()) }

    /// `clamp(100 - percent, 0, 100)`. Kept because the plans define it, and because
    /// some callers still want the complement — but it is no longer what the UI shows.
    public var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    /// 0…1 of consumption, for gauge fill height.
    ///
    /// The gauge fills as quota is spent rather than draining, because the number
    /// beside it is consumption too. Both Claude and Codex report usage natively, so
    /// showing it that way means one less conversion between what the provider says
    /// and what the user reads. Derived from the rounded figure so the drawn fill and
    /// the printed number can never disagree.
    public var usedFraction: Double { Double(usedPercent) / 100 }

    public var remainingFraction: Double { Double(remainingPercent) / 100 }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}
