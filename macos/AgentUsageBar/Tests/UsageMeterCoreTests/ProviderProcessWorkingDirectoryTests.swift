import Foundation
import Testing
@testable import UsageMeterCore

@Suite("供應商子程序工作目錄")
struct ProviderProcessWorkingDirectoryTests {
    @Test("建立本機、空白、僅限目前使用者的目錄並可精確清理")
    func createsAndRemovesAPrivateLocalDirectory() throws {
        let workingDirectory = try ProviderProcessWorkingDirectory.create(for: .claude)
        defer { workingDirectory.remove() }

        let values = try workingDirectory.url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: workingDirectory.url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

        #expect(workingDirectory.url.path != "/")
        #expect(values.isDirectory == true)
        #expect(values.isSymbolicLink != true)
        #expect(values.volumeIsLocal == true)
        #expect(permissions.intValue & 0o777 == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workingDirectory.url.path).isEmpty)

        workingDirectory.remove()
        #expect(!FileManager.default.fileExists(atPath: workingDirectory.url.path))
    }

    @Test("不安全的根目錄直接失敗，不得退回使用")
    func rejectsTheFilesystemRoot() {
        #expect(throws: ProviderProcessWorkingDirectory.CreationError.unsafeBaseDirectory) {
            try ProviderProcessWorkingDirectory.create(
                for: .codex,
                baseDirectory: URL(fileURLWithPath: "/", isDirectory: true)
            )
        }
    }

    @Test("固定名稱目錄每次清空重建，路徑不變且僅限目前使用者")
    func reusableDirectoryKeepsItsPathAndStartsEmpty() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try ProviderProcessWorkingDirectory.createReusable(named: "probe-workspace", baseDirectory: base)
        try Data("left behind\n".utf8).write(to: first.url.appendingPathComponent("leftover.txt"))
        try FileManager.default.createDirectory(
            at: first.url.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: false
        )

        let second = try ProviderProcessWorkingDirectory.createReusable(named: "probe-workspace", baseDirectory: base)
        defer { second.remove() }
        let attributes = try FileManager.default.attributesOfItem(atPath: second.url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

        #expect(second.url.path == first.url.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.url.path).isEmpty)
        #expect(permissions.intValue & 0o777 == 0o700)
    }

    @Test("固定路徑上的符號連結只移除連結本身，不跟隨到目標")
    func reusableDirectoryReplacesASymbolicLinkWithoutFollowingIt() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let kept = outside.appendingPathComponent("kept.txt")
        try Data("not the app's\n".utf8).write(to: kept)
        let root = try ProviderProcessWorkingDirectory.preparedPrivateRoot(baseDirectory: base).root
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("probe-workspace"),
            withDestinationURL: outside
        )

        let directory = try ProviderProcessWorkingDirectory.createReusable(named: "probe-workspace", baseDirectory: base)
        defer { directory.remove() }
        let values = try directory.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(values.isDirectory == true)
        #expect(values.isSymbolicLink != true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test("固定名稱必須是單一路徑元件", arguments: ["", ".", "..", "a/b", "../escape"])
    func reusableDirectoryRejectsUnsafeNames(name: String) throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(throws: ProviderProcessWorkingDirectory.CreationError.unsafeCreatedDirectory) {
            try ProviderProcessWorkingDirectory.createReusable(named: name, baseDirectory: base)
        }
    }

    /// Each test gets its own base so none of them touches the fixed workspace a running
    /// copy of the app may be using.
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-bar-workdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        return base
    }
}
