import Darwin
import Foundation

/// One empty, local, app-owned working directory for one provider subprocess.
///
/// Provider CLIs must never inherit the GUI app's current directory. LaunchServices
/// normally starts an App at `/`; treating that as a project lets a CLI inspect the
/// filesystem root and can trigger unrelated macOS Files & Folders prompts.
struct ProviderProcessWorkingDirectory: Sendable {
    enum CreationError: Error, Equatable {
        case unsafeBaseDirectory
        case unsafeCreatedDirectory
        case createdDirectoryWasNotEmpty
    }

    let url: URL

    static func create(
        for provider: ProviderKind,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        let fileManager = FileManager.default
        let (resolvedBase, validatedRoot) = try preparedPrivateRoot(baseDirectory: baseDirectory)

        let directory = validatedRoot.appendingPathComponent(
            "\(provider.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let validatedDirectory = try validate(directory, below: resolvedBase)
            guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw CreationError.createdDirectoryWasNotEmpty
            }
            return Self(url: validatedDirectory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// The same private, empty, local `0700` directory as `create(for:)`, but at one
    /// fixed path that every run reuses.
    ///
    /// Some CLIs keep state keyed by the working directory's path. Measured 2026-11-22
    /// against `agy` 1.5.14: every new path left one more file under
    /// `~/.gemini/antigravity-cli/implicit/`, a location this app does not own and must
    /// not clean, while repeated runs at one path added nothing. Reusing the path keeps
    /// that state to a single entry; clearing and recreating it keeps each run starting
    /// from an empty directory.
    ///
    /// Whatever is at the path is removed without following symbolic links. Callers must
    /// serialize runs (the Antigravity runner holds a cross-process lock), because a
    /// second caller would clear the directory under the first one.
    static func createReusable(
        named name: String,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CreationError.unsafeCreatedDirectory
        }
        let fileManager = FileManager.default
        let (resolvedBase, validatedRoot) = try preparedPrivateRoot(baseDirectory: baseDirectory)
        let directory = validatedRoot.appendingPathComponent(name, isDirectory: true)

        // `attributesOfItem` does not follow a final symbolic link, and `removeItem`
        // deletes a link itself rather than its target.
        if (try? fileManager.attributesOfItem(atPath: directory.path)) != nil {
            try fileManager.removeItem(at: directory)
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let validatedDirectory = try validate(directory, below: resolvedBase)
            guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw CreationError.createdDirectoryWasNotEmpty
            }
            return Self(url: validatedDirectory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// The app's own `0700` folder below a local, non-root temporary base. Every
    /// provider working directory, and any lock file guarding one, lives directly inside it.
    static func preparedPrivateRoot(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> (base: URL, root: URL) {
        let fileManager = FileManager.default
        let resolvedBase = try canonicalURL(baseDirectory)
        guard resolvedBase.path != "/" else { throw CreationError.unsafeBaseDirectory }

        let baseValues = try resolvedBase.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard baseValues.isDirectory == true, baseValues.volumeIsLocal == true else {
            throw CreationError.unsafeBaseDirectory
        }

        let root = resolvedBase.appendingPathComponent(
            "io.github.sean.AgentUsageBar",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        return (resolvedBase, try validate(root, below: resolvedBase))
    }

    func environment(
        basedOn base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PWD"] = url.path
        return environment
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard let resolvedPath = Darwin.realpath(url.path, nil) else {
            throw CreationError.unsafeBaseDirectory
        }
        defer { Darwin.free(resolvedPath) }
        return URL(
            fileURLWithFileSystemRepresentation: resolvedPath,
            isDirectory: true,
            relativeTo: nil
        )
    }

    private static func validate(_ directory: URL, below base: URL) throws -> URL {
        let unresolvedValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey]
        )
        let resolved = try canonicalURL(directory)
        guard unresolvedValues.isDirectory == true,
              unresolvedValues.isSymbolicLink != true,
              unresolvedValues.volumeIsLocal == true,
              resolved.path != "/",
              resolved.path.hasPrefix(base.path + "/") else {
            throw CreationError.unsafeCreatedDirectory
        }
        return resolved
    }
}
