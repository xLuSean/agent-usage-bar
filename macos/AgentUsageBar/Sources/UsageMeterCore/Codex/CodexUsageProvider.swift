import Foundation

public struct CodexUsageProvider: UsageProvider {
    public let configuredExecutablePath: String?
    private let client: any CodexAppServerReading

    public init(
        configuredExecutablePath: String? = nil,
        client: any CodexAppServerReading = CodexAppServerClient.shared
    ) {
        self.configuredExecutablePath = configuredExecutablePath
        self.client = client
    }

    public func fetch() async throws -> UsageSnapshot {
        let quota = try await fetchRateLimits(preserving: nil)
        let accountUsage: CodexAccountUsage?
        do {
            accountUsage = try await fetchAccountUsage()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Account totals are an optional enhancement. An older App Server, a timeout,
            // or a changed optional schema must not erase a trustworthy quota reading.
            accountUsage = nil
        }
        return accountUsage.map(quota.replacingCodexAccountUsage) ?? quota
    }

    /// Reads only the fast-moving quota surface while carrying forward the latest
    /// independently fetched token statistics.
    public func fetchRateLimits(
        preserving accountUsage: CodexAccountUsage?
    ) async throws -> UsageSnapshot {
        let rateLimitResponse = try await client.readRateLimits(
            configuredExecutablePath: configuredExecutablePath
        )
        return try CodexRateLimitDecoder.decode(
            rateLimitResponse.payload,
            fetchedAt: Date(),
            serverUserAgent: rateLimitResponse.serverUserAgent,
            accountUsage: accountUsage
        )
    }

    /// Reads only Codex's account token statistics. The caller owns merge and pacing so
    /// a failure cannot demote a valid quota snapshot.
    public func fetchAccountUsage(fetchedAt: Date = Date()) async throws -> CodexAccountUsage {
        let response = try await client.readAccountUsage(
            configuredExecutablePath: configuredExecutablePath
        )
        return try CodexAccountUsageDecoder.decode(response.payload, fetchedAt: fetchedAt)
    }
}
