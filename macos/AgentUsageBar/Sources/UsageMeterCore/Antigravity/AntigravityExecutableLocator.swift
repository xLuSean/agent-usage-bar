import Foundation

/// Finds the `agy` (Antigravity CLI) executable for a GUI app.
///
/// A GUI app's `PATH` is inherited from `launchd`, not the user's shell, so common
/// install locations are checked before falling back to `PATH`.
public struct AntigravityExecutableLocator: Sendable {
    public let configuredPath: String?
    public let environment: [String: String]
    private let commonCandidatePaths: [String]

    public init(
        configuredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configuredPath = configuredPath
        self.environment = environment
        self.commonCandidatePaths = Self.defaultCommonCandidatePaths
    }

    init(
        configuredPath: String? = nil,
        environment: [String: String],
        commonCandidatePaths: [String]
    ) {
        self.configuredPath = configuredPath
        self.environment = environment
        self.commonCandidatePaths = commonCandidatePaths
    }

    public func locate() throws -> URL {
        let explicit = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return try validate(path: explicit, isExplicit: true)
        }
        for path in candidatePaths {
            if let url = try? validate(path: path, isExplicit: false) { return url }
        }
        throw UsageError.antigravityExecutableNotFound
    }

    /// Ordered and de-duplicated. `ANTIGRAVITY_EXECUTABLE` is a development convenience;
    /// the app's own setting remains the user-facing authority.
    public var candidatePaths: [String] {
        var candidates: [String] = []
        if let override = environment["ANTIGRAVITY_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: commonCandidatePaths)
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("agy").path
            })
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static var defaultCommonCandidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            home.appendingPathComponent(".local/bin/agy").path,
            home.appendingPathComponent(".antigravity/bin/agy").path,
        ]
    }

    private func validate(path: String, isExplicit: Bool) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, fileManager.isExecutableFile(atPath: url.path) else {
            if isExplicit { throw UsageError.antigravityExecutableInvalid(path) }
            throw UsageError.antigravityExecutableNotFound
        }
        return url
    }
}
