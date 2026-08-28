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
        let validatedRoot = try validate(root, below: resolvedBase)

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
