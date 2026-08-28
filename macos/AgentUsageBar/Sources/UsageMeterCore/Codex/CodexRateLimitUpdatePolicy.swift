import Foundation

/// Applies a sparse Codex rate-limit notification without pretending it is a complete
/// `account/rateLimits/read` response.
///
/// Notifications may omit the weekly window and account metadata. Missing values mean
/// "not supplied by this update", not "erase what the last complete read knew". The
/// next scheduled full read remains responsible for correcting the complete snapshot.
public enum CodexRateLimitUpdatePolicy {
    public static func applying(
        _ update: UsageSnapshot,
        to state: UsageDisplayState
    ) -> UsageDisplayState? {
        switch state {
        case .starting, .unavailable:
            return nil

        case .current(let base):
            guard let merged = merge(update, into: base) else { return nil }
            return .current(merged)

        case .stale(let base, let reason):
            guard let merged = merge(update, into: base) else { return nil }
            return .stale(merged, reason: reason)

        case .refreshing(let previous):
            guard let previous, let merged = merge(update, into: previous) else { return nil }
            return .refreshing(previous: merged)

        case .throttled(let previous, let until):
            guard let previous, let merged = merge(update, into: previous) else { return nil }
            return .throttled(previous: merged, until: until)
        }
    }

    private static func merge(
        _ update: UsageSnapshot,
        into base: UsageSnapshot
    ) -> UsageSnapshot? {
        guard isGeneralCodexSnapshot(base), isGeneralCodexSnapshot(update) else { return nil }
        guard !base.windows.isEmpty, !update.windows.isEmpty else { return nil }

        var updateByID: [String: UsageWindow] = [:]
        for window in update.windows {
            updateByID[window.id] = window
        }

        let baseIDs = Set(base.windows.map(\.id))
        var windows = base.windows.map { updateByID[$0.id] ?? $0 }
        var appendedIDs = baseIDs
        for window in update.windows where appendedIDs.insert(window.id).inserted {
            windows.append(updateByID[window.id] ?? window)
        }

        return UsageSnapshot(
            provider: base.provider,
            sourcePath: base.sourcePath,
            windows: windows,
            // A notification is not a complete successful read. Keep the timestamp
            // honest so freshness and the scheduled safety poll retain their meaning.
            fetchedAt: base.fetchedAt,
            credits: update.credits ?? base.credits,
            planType: update.planType ?? base.planType,
            rateLimitReachedType: update.rateLimitReachedType ?? base.rateLimitReachedType,
            spendControlReached: update.spendControlReached ?? base.spendControlReached,
            meteredLimitID: update.meteredLimitID ?? base.meteredLimitID,
            sourceVersion: update.sourceVersion ?? base.sourceVersion
        )
    }

    private static func isGeneralCodexSnapshot(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.provider == .codex
            && snapshot.sourcePath == .codexAppServer
            && (snapshot.meteredLimitID == nil || snapshot.meteredLimitID == "codex")
    }
}
