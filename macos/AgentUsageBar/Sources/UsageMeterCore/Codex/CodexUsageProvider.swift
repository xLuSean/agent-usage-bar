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
        try await CodexQueryFailure.withOriginalError { try await quotaReading(preserving: accountUsage).snapshot }
    }

    public func quotaReading(
        preserving accountUsage: CodexAccountUsage?
    ) async throws -> (snapshot: UsageSnapshot, query: CodexQueryDiagnostic?) {
        let rateLimitResponse = try await client.readWithDiagnostics(.quota, configuredExecutablePath: configuredExecutablePath)
        let snapshot = try rateLimitResponse.decode {
            try CodexRateLimitDecoder.decode(
                $0, fetchedAt: Date(), serverUserAgent: rateLimitResponse.serverUserAgent, accountUsage: accountUsage
            )
        }
        return (snapshot, rateLimitResponse.diagnostic)
    }

    /// Reads only Codex's account token statistics. The caller owns merge and pacing so
    /// a failure cannot demote a valid quota snapshot.
    public func fetchAccountUsage(fetchedAt: Date = Date()) async throws -> CodexAccountUsage {
        try await CodexQueryFailure.withOriginalError { try await tokenReading(fetchedAt: fetchedAt).usage }
    }

    public func tokenReading(fetchedAt: Date) async throws -> (usage: CodexAccountUsage, query: CodexQueryDiagnostic?) {
        let response = try await client.readWithDiagnostics(.tokenUsage, configuredExecutablePath: configuredExecutablePath)
        let usage = try response.decode { try CodexAccountUsageDecoder.decode($0, fetchedAt: fetchedAt) }
        return (usage, response.diagnostic)
    }
}
