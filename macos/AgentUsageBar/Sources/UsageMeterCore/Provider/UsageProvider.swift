import Foundation

/// One reading, from wherever. Kept this narrow so Claude's one-shot CLI command and
/// Codex's local JSON-RPC connection can share the UI without either being bent toward
/// the other.
public protocol UsageProvider: Sendable {
    func fetch() async throws -> UsageSnapshot
}
