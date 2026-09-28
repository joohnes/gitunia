import XCTest
@testable import GituniaCore

final class WorkspaceFileTests: XCTestCase {
    func testRelativizeSiblingAndChildAndSelf() {
        let base = URL(fileURLWithPath: "/Users/me/Projects/ws")
        XCTAssertEqual(WorkspaceFile.relativize("/Users/me/Projects/gitunia", to: base), "../gitunia")
        XCTAssertEqual(WorkspaceFile.relativize("/Users/me/Projects/ws/a/b", to: base), "a/b")
        XCTAssertEqual(WorkspaceFile.relativize("/Users/me/Projects/ws", to: base), ".")
        XCTAssertEqual(WorkspaceFile.relativize("/opt/x", to: base), "../../../../opt/x")
    }

    func testResolveRelativeAbsoluteAndTilde() {
        let base = URL(fileURLWithPath: "/Users/me/Projects/ws")
        XCTAssertEqual(WorkspaceFile.resolve("../gitunia", relativeTo: base), "/Users/me/Projects/gitunia")
        XCTAssertEqual(WorkspaceFile.resolve("/opt/x/", relativeTo: base), "/opt/x")
        XCTAssertEqual(WorkspaceFile.resolve("~/code", relativeTo: base),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code").standardizedFileURL.path)
        XCTAssertEqual(WorkspaceFile.resolve(".", relativeTo: base), "/Users/me/Projects/ws")
    }

    func testRoundTripWritesRelativePathsAndReadsBackAbsolute() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("ws/team.gitunia-workspace")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let repo = dir.appendingPathComponent("gitunia").path
        let folder = dir.appendingPathComponent("agents").path
        let file = WorkspaceFile(
            repositories: [repo],
            folders: [.init(path: folder, excluded: ["old"])],
            tags: [repo: ["core"]]
        )
        try file.save(to: fileURL)

        let json = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"../gitunia\""), json)
        XCTAssertTrue(json.contains("\"../agents\""), json)
        XCTAssertTrue(json.contains("\"version\" : 1"), json)
        XCTAssertFalse(json.contains(dir.path), "no absolute paths for same-volume entries: \(json)")

        let loaded = try WorkspaceFile.load(from: fileURL)
        XCTAssertEqual(loaded, WorkspaceFile(
            repositories: [WorkspaceFile.standardize(repo)],
            folders: [.init(path: WorkspaceFile.standardize(folder), excluded: ["old"])],
            tags: [WorkspaceFile.standardize(repo): ["core"]]
        ))
    }

    func testSaveWithAbsolutePathsForUntitled() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("u.gitunia-workspace")
        let repo = dir.appendingPathComponent("r").path
        try WorkspaceFile(repositories: [repo]).save(to: fileURL, relativePaths: false)
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(json.contains(WorkspaceFile.standardize(repo)), json)
    }

    func testLoadToleratesMissingKeysAndUnknownKeys() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("w.gitunia-workspace")
        try #"{"version": 1, "folders": [{"path": "x"}], "future": true}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let loaded = try WorkspaceFile.load(from: fileURL)
        XCTAssertEqual(loaded.repositories, [])
        XCTAssertEqual(loaded.folders, [.init(path: WorkspaceFile.standardize(dir.appendingPathComponent("x").path), excluded: [])])
        XCTAssertEqual(loaded.tags, [:])
    }
}
