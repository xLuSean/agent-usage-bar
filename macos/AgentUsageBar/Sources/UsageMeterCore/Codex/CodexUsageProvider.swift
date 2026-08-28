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
        let response = try await client.readRateLimits(
            configuredExecutablePath: configuredExecutablePath
        )
        return try CodexRateLimitDecoder.decode(
            response.payload,
            fetchedAt: Date(),
            serverUserAgent: response.serverUserAgent
        )
    }
}
