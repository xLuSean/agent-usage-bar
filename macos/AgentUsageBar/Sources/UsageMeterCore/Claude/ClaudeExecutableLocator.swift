import Foundation

/// Finds the `claude` executable for a GUI app.
///
/// A GUI app's `PATH` is whatever `launchd` handed it, not the user's shell PATH, so
/// the shell's `which claude` is no guide at all here. This checks the known install
/// locations first and only then falls back to whatever `PATH` happens to hold.
///
/// Modelled on `CodexExecutableLocator`, which solves the same problem for the same
/// reason. Kept as a separate type rather than generalised: the two CLIs have different
/// install conventions and different errors, and a shared abstraction would have to be
/// parameterised on both.
public struct ClaudeExecutableLocator: Sendable {
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
        throw UsageError.claudeExecutableNotFound
    }

    /// Ordered and de-duplicated. `CLAUDE_EXECUTABLE` is a development convenience;
    /// the app's own setting stays the user-facing authority.
    public var candidatePaths: [String] {
        var candidates: [String] = []
        if let override = environment["CLAUDE_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: commonCandidatePaths)
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("claude").path
            })
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static var defaultCommonCandidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
        ]
    }

    private func validate(path: String, isExplicit: Bool) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, fileManager.isExecutableFile(atPath: url.path) else {
            if isExplicit { throw UsageError.claudeExecutableInvalid(path) }
            throw UsageError.claudeExecutableNotFound
        }
        return url
    }

    /// Version read from the resolved install path, when the path carries one.
    ///
    /// Homebrew installs `claude` as a symlink into a versioned directory, so the
    /// version falls out of the path without executing anything. This is now only a
    /// diagnostic — the User-Agent it used to feed is gone with the HTTP path — so a
    /// `nil` here is not a failure and nothing downstream depends on it.
    public static func detectedVersion(at url: URL) -> String? {
        let pattern = /claude-code\/(\d+\.\d+\.\d+)\//
        guard let match = url.path.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }
}
