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
        guard Set(base.windows.map(mergeID)).count == base.windows.count,
              Set(update.windows.map(mergeID)).count == update.windows.count else { return nil }

        var updateByID: [String: UsageWindow] = [:]
        for window in update.windows {
            updateByID[mergeID(window)] = window
        }

        let baseIDs = Set(base.windows.map(mergeID))
        var windows = base.windows.map { previous in
            guard let incoming = updateByID[mergeID(previous)] else { return previous }
            let sameDuration = incoming.durationMinutes == nil || incoming.durationMinutes == previous.durationMinutes
            let previousReset = previous.resetsAt.flatMap { sameDuration && $0 > update.fetchedAt ? $0 : nil }
            let duration = incoming.durationMinutes ?? previous.durationMinutes
            let slot = incoming.sourceSlot ?? previous.sourceSlot ?? legacySlot(previous)
            let (kind, group) = slot.map {
                CodexRateLimitDecoder.classification(duration: duration, position: $0)
            } ?? (incoming.kind, incoming.group)
            return UsageWindow(
                kind: kind, group: group, used: incoming.used,
                resetsAt: incoming.resetsAt ?? previousReset, isActive: incoming.isActive,
                modelDisplayName: incoming.modelDisplayName,
                durationMinutes: duration,
                sourceSlot: slot
            )
        }
        var appendedIDs = baseIDs
        for window in update.windows where appendedIDs.insert(mergeID(window)).inserted {
            windows.append(updateByID[mergeID(window)] ?? window)
        }
        let knownKinds = windows.filter { $0.kind == .session || $0.kind == .weeklyAll }.map(\.kind)
        guard Set(knownKinds).count == knownKinds.count else { return nil }

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
            sourceVersion: update.sourceVersion ?? base.sourceVersion,
            // Rate-limit notifications do not carry account token history. Preserve the
            // last complete read until the next scheduled account usage request.
            codexAccountUsage: update.codexAccountUsage ?? base.codexAccountUsage
        )
    }

    private static func legacySlot(_ window: UsageWindow) -> UsageWindow.SourceSlot? {
        switch window.kind {
        case .session: .primary
        case .weeklyAll: .secondary
        default: nil
        }
    }

    private static func mergeID(_ window: UsageWindow) -> String {
        if let slot = window.sourceSlot ?? legacySlot(window) { return "codex_\(slot.rawValue)" }
        return window.id
    }

    private static func isGeneralCodexSnapshot(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.provider == .codex
            && snapshot.sourcePath == .codexAppServer
            && (snapshot.meteredLimitID == nil || snapshot.meteredLimitID == "codex")
    }
}
