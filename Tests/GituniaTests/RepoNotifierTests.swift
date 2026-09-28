import XCTest
@testable import Gitunia
import GituniaCore

@MainActor
final class RepoNotifierTests: XCTestCase {
    func testSingleHeadMoveCarriesTheHash() {
        let info = RepoNotifier.userInfo(for: [.headMoved(from: "a1", to: "b2")], repoPath: "/r")
        XCTAssertEqual(info, ["repoPath": "/r", "hash": "b2"])
    }

    func testSeveralEventsCarryNoHash() {
        let info = RepoNotifier.userInfo(for: [.headMoved(from: "a1", to: "b2"), .branchAdded("x")], repoPath: "/r")
        XCTAssertEqual(info, ["repoPath": "/r"])
    }

    func testRemoteUpdateCarriesItsNewOID() {
        let e = ActivityEvent(repoPath: "/r", repoName: "r", kind: .branchUpdated, ref: "origin/main", oldOID: "a1", newOID: "c3")
        XCTAssertEqual(RepoNotifier.userInfo(for: [.remoteActivity(e)], repoPath: "/r")["hash"], "c3")
    }

    /// B14: a notification for a repo no open window has — `openFromNotification`'s fallback looks
    /// through recent `.gitunia-workspace` files for one that lists it. Tested at the pure-lookup
    /// level (`workspaceURL(containing:recent:)`), since driving `openFromNotification` end to end
    /// needs a real window to attach the repo to.
    func testWorkspaceURLContainingFindsDirectListing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-wf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("w.gitunia-workspace")
        try WorkspaceFile(repositories: [repo.path]).save(to: file, relativePaths: false)

        XCTAssertEqual(WorkspaceRegistry.workspaceURL(containing: repo.path, recent: [file.path]), file)
        XCTAssertNil(WorkspaceRegistry.workspaceURL(containing: dir.appendingPathComponent("other").path, recent: [file.path]))
    }

    func testWorkspaceURLContainingFindsRepoUnderLinkedFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-wf-\(UUID().uuidString)")
        let folder = dir.appendingPathComponent("folder")
        let repo = folder.appendingPathComponent("nested/repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("w.gitunia-workspace")
        try WorkspaceFile(folders: [WorkspaceFile.Folder(path: folder.path)]).save(to: file, relativePaths: false)

        XCTAssertEqual(WorkspaceRegistry.workspaceURL(containing: repo.path, recent: [file.path]), file)
    }

    func testWorkspaceURLContainingSkipsUnreadableFiles() {
        XCTAssertNil(WorkspaceRegistry.workspaceURL(containing: "/tmp/whatever", recent: ["/nonexistent.gitunia-workspace"]))
    }

    func testTapParsesUserInfoAndCallsTheHook() {
        var got: (String, String?)?
        let saved = AppDelegate.onNotificationTap
        defer { AppDelegate.onNotificationTap = saved }
        AppDelegate.onNotificationTap = { got = ($0, $1) }

        XCTAssertNil(AppDelegate.handleNotificationTap(userInfo: [:]))
        XCTAssertNil(got)
        let tap = AppDelegate.handleNotificationTap(userInfo: ["repoPath": "/r", "hash": "b2"])
        XCTAssertEqual(tap?.repoPath, "/r")
        XCTAssertEqual(got?.0, "/r")
        XCTAssertEqual(got?.1, "b2")
    }
}
