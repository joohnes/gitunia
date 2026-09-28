import XCTest
@testable import GituniaCore

/// `git worktree add/remove/prune` against throwaway temp repos.
@MainActor
final class WorktreeOpsTests: XCTestCase {
    private func makeStore() async throws -> (RepositoryStore, URL) {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return (store, url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-wt"))
    }

    /// git reports realpaths (`/private/var/…`), so compare resolved.
    private func listed(_ store: RepositoryStore, _ wt: URL) async throws -> Worktree? {
        let target = wt.resolvingSymlinksInPath().path
        return try await store.worktrees().first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target || $0.path == "/private" + target }
    }

    func testAddWithNewBranchThenRemoveClean() async throws {
        let (store, wtURL) = try await makeStore()
        let addError = await store.addWorktree(path: wtURL, branch: "feature/x", createBranch: true)
        XCTAssertNil(addError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtURL.appendingPathComponent("README.md").path))
        let found = try await listed(store, wtURL)
        let wt = try XCTUnwrap(found)
        XCTAssertEqual(wt.branch, "feature/x")

        let removeError = await store.removeWorktree(wt, force: false)
        XCTAssertNil(removeError)
        let afterRemove = try await listed(store, wtURL)
        XCTAssertNil(afterRemove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtURL.path))
    }

    func testAddExistingBranchAndRejectInvalidName() async throws {
        let (store, wtURL) = try await makeStore()
        _ = try await GitRunner().run(["branch", "existing"], in: store.url)
        let invalid = await store.addWorktree(path: wtURL, branch: "bad..name", createBranch: true)
        XCTAssertNotNil(invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtURL.path))
        let ok = await store.addWorktree(path: wtURL, branch: "existing", createBranch: false)
        XCTAssertNil(ok)
        let wt = try await listed(store, wtURL)
        XCTAssertEqual(wt?.branch, "existing")
    }

    func testRemoveDirtyNeedsForce() async throws {
        let (store, wtURL) = try await makeStore()
        let addError = await store.addWorktree(path: wtURL, branch: "dirty", createBranch: true)
        XCTAssertNil(addError)
        try TestHelpers.write("scratch\n", to: wtURL, "untracked.txt")
        let found = try await listed(store, wtURL)
        let wt = try XCTUnwrap(found)

        let refused = await store.removeWorktree(wt, force: false)
        XCTAssertTrue(refused?.stderr.contains("--force") == true, refused?.stderr ?? "no error")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtURL.path))

        let forced = await store.removeWorktree(wt, force: true)
        XCTAssertNil(forced)
        let afterForce = try await listed(store, wtURL)
        XCTAssertNil(afterForce)
    }

    func testPruneDropsDeletedFolder() async throws {
        let (store, wtURL) = try await makeStore()
        let addError = await store.addWorktree(path: wtURL, branch: "gone", createBranch: true)
        XCTAssertNil(addError)
        try FileManager.default.removeItem(at: wtURL)
        let prunable = try await listed(store, wtURL)
        XCTAssertEqual(prunable?.isPrunable, true)

        let pruneError = await store.pruneWorktrees()
        XCTAssertNil(pruneError)
        let afterPrune = try await listed(store, wtURL)
        XCTAssertNil(afterPrune)
    }
}
