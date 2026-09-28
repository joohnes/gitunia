import XCTest
@testable import GituniaCore

final class WorkspaceScannerTests: XCTestCase {
    private func mkdir(_ base: URL, _ path: String) throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func testFindsReposAndSkipsNoise() throws {
        let root = try TestHelpers.makeTempDir()
        try mkdir(root, "a/.git")
        try mkdir(root, "group/b/.git")
        try mkdir(root, "node_modules/pkg/.git")
        try mkdir(root, ".hidden/c/.git")
        try mkdir(root, "a/nested/.git")           // inside a repo: skipped
        try mkdir(root, "d1/d2/d3/deep/.git")      // depth 4: skipped with maxDepth 3
        try mkdir(root, "plain")

        let found = WorkspaceScanner.findRepositories(in: root).map { $0.lastPathComponent }
        XCTAssertEqual(found, ["a", "b"])
    }

    func testRootItselfIsRepo() throws {
        let root = try TestHelpers.makeTempDir()
        try mkdir(root, ".git")
        try mkdir(root, "sub/.git")
        XCTAssertEqual(WorkspaceScanner.findRepositories(in: root), [root.standardizedFileURL])
    }
}
