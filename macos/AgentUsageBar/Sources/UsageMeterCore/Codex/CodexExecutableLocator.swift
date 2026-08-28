import Foundation

/// Locates the Codex CLI for a GUI app, whose PATH is often much smaller than the
/// user's interactive shell PATH.
public struct CodexExecutableLocator: Sendable {
    public let configuredPath: String?
    public let environment: [String: String]
    private let commonCandidatePaths: [String]

    public init(
        configuredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configuredPath = configuredPath
        self.environment = environment
        commonCandidatePaths = Self.defaultCommonCandidatePaths
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
            if let url = try? validate(path: path, isExplicit: false) {
                return url
            }
        }
        throw UsageError.codexExecutableNotFound
    }

    /// Ordered, de-duplicated candidates. The environment override is primarily useful
    /// for development; the App's persisted setting remains the user-facing authority.
    public var candidatePaths: [String] {
        var candidates: [String] = []
        if let override = environment["CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: commonCandidatePaths)
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex").path
            })
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static var defaultCommonCandidatePaths: [String] {
        [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex").path,
        ]
    }

    private func validate(path: String, isExplicit: Bool) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            if isExplicit {
                throw UsageError.codexExecutableInvalid(path)
            }
            throw UsageError.codexExecutableNotFound
        }
        return url
    }
}
