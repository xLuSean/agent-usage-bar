import Foundation

/// Keeps the most recent reading across launches. One per provider, overwritten every
/// time — there is no history here and none is wanted.
///
/// This exists to avoid asking again for something already known. A relaunch used to
/// mean an immediate request no matter how recently one had been made; now the app
/// starts with what it had and only asks when that has aged out.
///
/// What lands on disk is the normalized snapshot shown by the app: usage windows,
/// timestamps, and provider-supplied account metadata such as plan or Credits. Raw
/// provider output and credential material never pass through this type.
public struct UsageSnapshotStore {

    private let defaults: UserDefaults
    private let version = "v1"
    private static let maximumSnapshotBytes = 65_536

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ provider: ProviderKind) -> String {
        "\(version).snapshot.\(provider.rawValue)"
    }

    public func load(_ provider: ProviderKind, now: Date = Date()) -> UsageSnapshot? {
        guard let data = defaults.data(forKey: key(provider)) else { return nil }
        guard data.count <= Self.maximumSnapshotBytes else { return nil }
        guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data),
              snapshot.isValidPersistedReading(for: provider, now: now) else { return nil }
        return snapshot
    }

    public func save(_ snapshot: UsageSnapshot) {
        guard snapshot.isValidPersistedReading(for: snapshot.provider, now: nil) else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard data.count <= Self.maximumSnapshotBytes else { return }
        defaults.set(data, forKey: key(snapshot.provider))
    }

    public func clear(_ provider: ProviderKind) {
        defaults.removeObject(forKey: key(provider))
    }
}

private extension UsageSnapshot {
    func isValidPersistedReading(for expectedProvider: ProviderKind, now: Date?) -> Bool {
        guard provider == expectedProvider,
              !windows.isEmpty,
              hasSafeProviderMetadata else { return false }

        if let now {
            // A future wall-clock timestamp can survive a clock rollback or a damaged
            // defaults value. It is not evidence that the reading is fresh.
            guard fetchedAt <= now else { return false }

            // A persisted reading may have been fetched shortly before its quota window
            // rolled over. Freshness by fetch age alone would then restore an obsolete
            // percentage as "current" after relaunch. Use the same small boundary grace
            // as the Claude live decoder; nil means the provider reported no active reset.
            let resetGrace: TimeInterval = 60
            guard windows.allSatisfy({ window in
                guard let resetsAt = window.resetsAt else { return true }
                return resetsAt.addingTimeInterval(resetGrace) >= now
            }) else { return false }
        }

        // Retired Claude sources stay readable for one-release upgrade continuity, but
        // a source can never cross provider boundaries and fixture data is never real.
        switch (provider, sourcePath) {
        case (.claude, .claudeCodeCLI):
            // The current Claude decoder produces exactly one session and one weekly
            // window. Keep its missing-reset rules at the persistence boundary too, so
            // a damaged or older defaults payload cannot bypass the live fail-closed
            // decoder during launch. Extra future window kinds remain forward-compatible.
            let sessions = windows.filter { $0.kind == .session }
            let weeklyAll = windows.filter { $0.kind == .weeklyAll }
            guard sessions.count == 1,
                  weeklyAll.count == 1,
                  let session = sessions.first,
                  let weekly = weeklyAll.first,
                  session.resetsAt != nil || session.used.usedPercent == 0,
                  weekly.resetsAt != nil else { return false }
            return true
        case (.claude, .usageEndpoint),
             (.claude, .messagesFallback),
             (.codex, .codexAppServer):
            return true
        case (_, .fixture),
             (.claude, .codexAppServer),
             (.codex, .claudeCodeCLI),
             (.codex, .usageEndpoint),
             (.codex, .messagesFallback):
            return false
        }
    }

    var hasSafeProviderMetadata: Bool {
        guard ProviderMetadataText.isSafeDisplay(credits?.balance),
              ProviderMetadataText.isSafeDisplay(planType),
              ProviderMetadataText.isSafeDisplay(rateLimitReachedType),
              ProviderMetadataText.isSafeDisplay(sourceVersion) else { return false }

        if let meteredLimitID,
           !ProviderMetadataText.isSafeIdentifier(meteredLimitID) {
            return false
        }

        return windows.allSatisfy { window in
            ProviderMetadataText.isSafeDisplay(window.modelDisplayName)
                && ProviderMetadataText.isSafeDisplay(window.kind.rawValue)
                && ProviderMetadataText.isSafeDisplay(window.group.rawValue)
        }
    }
}
