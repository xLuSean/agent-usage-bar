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
}
