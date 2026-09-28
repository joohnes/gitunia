import XCTest
@testable import Gitunia
import GituniaCore

@MainActor
final class RepoNotifierTests: XCTestCase {
    func testWorkspaceURLContainingFindsRepoUnderLinkedFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-wf-\(UUID().uuidString)")
        let folder = dir.appendingPathComponent("folder")
        let repo = folder.appendingPathComponent("nested/repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("w.gitunia-workspace")
        try WorkspaceFile(folders: [WorkspaceFile.Folder(path: folder.path)]).save(to: file, relativePaths: false)

        XCTAssertEqual(WorkspaceRegistry.workspaceURL(containing: repo.path, recent: [file.path]), file)
    }
}
