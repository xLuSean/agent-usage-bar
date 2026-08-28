/// Tracks independent system conditions that suspend provider polling.
///
/// macOS can report machine sleep, display sleep, and screen lock in overlapping
/// orders. A single Boolean cannot tell which condition is still active when one wake
/// notification arrives.
public struct PollingPauseState: Sendable, Equatable {
    public enum Reason: Sendable, Hashable {
        case systemSleep
        case displaySleep
        case screenLock
    }

    private var activeReasons: Set<Reason> = []

    public init() {}

    public var isPaused: Bool { !activeReasons.isEmpty }

    /// Updates one reason and returns whether the aggregate paused state changed.
    /// Duplicate and out-of-order notifications are intentionally idempotent.
    @discardableResult
    public mutating func set(_ active: Bool, for reason: Reason) -> Bool {
        let wasPaused = isPaused
        if active {
            activeReasons.insert(reason)
        } else {
            activeReasons.remove(reason)
        }
        return isPaused != wasPaused
    }
}
