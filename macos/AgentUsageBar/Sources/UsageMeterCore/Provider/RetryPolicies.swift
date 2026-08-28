import Foundation

/// Generic exponential retry parameters, held per provider.
public struct BackoffPolicy: Sendable, Hashable {
    public let initial: TimeInterval
    public let cap: TimeInterval
    public let multiplier: Double

    public init(
        initial: TimeInterval,
        cap: TimeInterval,
        multiplier: Double
    ) {
        self.initial = initial
        self.cap = cap
        self.multiplier = multiplier
    }

    public static let claude = BackoffPolicy(
        initial: 60,
        cap: 1800,
        multiplier: 2
    )

    public static let codex = BackoffPolicy(
        initial: 60,
        cap: 900,
        multiplier: 2
    )
}

extension BackoffPolicy {
    /// Chosen per provider. There is deliberately no default: picking one for a new
    /// provider is a decision about that provider's upstream, not a formality.
    public static func forProvider(_ provider: ProviderKind) -> BackoffPolicy {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// Tracks consecutive failures and answers "how long until the next attempt".
public struct RetryBackoff: Sendable {
    public let policy: BackoffPolicy
    public private(set) var consecutiveFailures: Int = 0

    public init(policy: BackoffPolicy = .claude) {
        self.policy = policy
    }

    public mutating func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        let exponent = Double(consecutiveFailures - 1)
        let raw = policy.initial * pow(policy.multiplier, exponent)
        guard raw.isFinite else { return policy.cap }
        return min(raw, policy.cap)
    }

    public mutating func reset() {
        consecutiveFailures = 0
    }
}
