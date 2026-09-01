import Foundation

/// Merges an independently refreshed account-token reading without changing quota
/// freshness or failure presentation. If no quota snapshot exists yet, the presenter
/// keeps the token reading briefly and applies it to the first successful quota read.
public enum CodexAccountUsageUpdatePolicy {
    public static func applying(
        _ accountUsage: CodexAccountUsage,
        to state: UsageDisplayState
    ) -> UsageDisplayState? {
        switch state {
        case .starting, .unavailable:
            return nil
        case .current(let snapshot):
            guard let snapshot = merge(accountUsage, into: snapshot) else { return nil }
            return .current(snapshot)
        case .stale(let snapshot, let reason):
            guard let snapshot = merge(accountUsage, into: snapshot) else { return nil }
            return .stale(snapshot, reason: reason)
        case .refreshing(let previous):
            guard let previous, let snapshot = merge(accountUsage, into: previous) else { return nil }
            return .refreshing(previous: snapshot)
        case .throttled(let previous, let until):
            guard let previous, let snapshot = merge(accountUsage, into: previous) else { return nil }
            return .throttled(
                previous: snapshot,
                until: until
            )
        }
    }

    private static func merge(
        _ accountUsage: CodexAccountUsage,
        into snapshot: UsageSnapshot
    ) -> UsageSnapshot? {
        guard snapshot.provider == .codex,
              snapshot.sourcePath == .codexAppServer else { return nil }
        return snapshot.replacingCodexAccountUsage(accountUsage)
    }
}
