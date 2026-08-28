import Foundation

/// Decides whether a fetch should actually go out.
///
/// # Why relaunching needed a rule
///
/// Without a persisted latest reading, every launch fired a request immediately.
/// Quitting and reopening ten times meant ten requests inside a minute. Nothing in the
/// polling schedule helped because a fresh process starts with an empty schedule.
///
/// Two rules, both about the same thing — not asking again for an answer that has not
/// had time to change:
///
/// - A reading younger than the poll interval is still good. Show it, and let the timer
///   run out the remainder rather than restarting it.
/// - Nothing may fetch twice within `floor`, whatever asked. This covers the paths a
///   schedule cannot see: relaunching, waking, unlocking, and a person clicking refresh
///   repeatedly because the number did not move.
public struct FetchPacing: Sendable, Equatable {

    /// Hard minimum between two requests, regardless of what triggered them.
    ///
    /// Deliberately short. It is there to absorb bursts, not to make the app feel
    /// unresponsive — a person who clicks refresh twice should wait, not be punished.
    public static let floor: TimeInterval = 20

    /// Why a fetch is being attempted. Scheduled and explicit manual requests have
    /// different freshness rules, but both obey the burst-protection floor.
    public enum Reason: Sendable, Equatable {
        /// The poll timer fired.
        case scheduled
        /// Someone pressed refresh.
        case manual
    }

    public enum Decision: Sendable, Equatable {
        case fetch
        /// The stored reading is new enough to keep using.
        case useStored(freshFor: TimeInterval)
        /// Something asked too soon after the last attempt.
        case tooSoon(retryAfter: TimeInterval)

        public var shouldFetch: Bool { self == .fetch }
    }

    /// - Parameters:
    ///   - lastAttemptAt: when a request last went out, from any trigger.
    ///   - storedFetchedAt: when the reading being shown was obtained.
    ///   - interval: the user's chosen poll interval.
    ///   - reason: what prompted this attempt. See `Reason`.
    public static func decide(
        lastAttemptAt: Date?,
        storedFetchedAt: Date?,
        interval: TimeInterval,
        reason: Reason,
        now: Date = Date()
    ) -> Decision {
        if let lastAttemptAt {
            let sinceAttempt = now.timeIntervalSince(lastAttemptAt)
            // A future wall-clock timestamp can survive a clock rollback. Treating it
            // as "very recent" would reschedule forever until the clock catches up.
            // Ignore it once so a successful fetch can replace the bad timestamp.
            if sinceAttempt >= 0, sinceAttempt < floor {
                return .tooSoon(retryAfter: floor - sinceAttempt)
            }
        }
        if reason == .manual { return .fetch }
        if let storedFetchedAt {
            let age = now.timeIntervalSince(storedFetchedAt)
            // The same rule applies to persisted readings: future data is not fresh
            // data. Fetch once rather than repeatedly extending an impossible age.
            if age >= 0, age < interval {
                return .useStored(freshFor: interval - age)
            }
        }
        return .fetch
    }
}
