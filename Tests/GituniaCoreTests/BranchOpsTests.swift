import XCTest
@testable import GituniaCore

/// T3: merge / rename / delete branch verbs, against real temp repos — same style as
/// `RemoteOpsTests`/`OperationTests`.
final class BranchOpsTests: XCTestCase {
    // MARK: - Merge

    @MainActor
    func testMergeFastForward() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("x\n", to: url, "x.txt")
        _ = try await git.run(["add", "x.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feature commit"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.mergeBranch("feature")
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.wasFastForward)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("x.txt").path))
    }

    @MainActor
    func testMergeCreatesAMergeCommitWhenNotFastForwardable() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("feature\n", to: url, "feature.txt")
        _ = try await git.run(["add", "feature.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feature commit"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("master\n", to: url, "master.txt")
        _ = try await git.run(["add", "master.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "master commit"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.mergeBranch("feature")
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.wasFastForward)
        let parents = try await git.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: url)
        XCTAssertEqual(parents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").count, 3)
    }

    @MainActor
    func testMergeConflictLeavesMergeOperationInProgressAndContinueCommits() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("hello\nfeature-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "feature change"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("hello\nmain-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "master change"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.mergeBranch("feature")
        XCTAssertFalse(result.succeeded)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .merge)
        XCTAssertEqual(store.conflictedChanges.map(\.path), ["README.md"])

        _ = await store.useTheirs(store.conflictedChanges[0])
        let continued = await store.continueOperation()
        XCTAssertTrue(continued)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        let content = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "hello\nfeature-line")
    }

    // MARK: - Rename

    @MainActor
    func testRenameBranchSucceeds() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.renameBranch("master", to: "trunk")
        XCTAssertEqual(result, .succeeded(keptOldRemoteName: false))
        await store.refreshStatus()
        XCTAssertEqual(store.repo.branch, "trunk")
    }

    @MainActor
    func testRenameBranchSaysRemoteKeepsOldNameWhenUpstreamExists() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        let store = RepositoryStore(url: repo)
        _ = await store.push()
        XCTAssertTrue(store.hasUpstream)

        let result = await store.renameBranch("master", to: "trunk")
        XCTAssertEqual(result, .succeeded(keptOldRemoteName: true))
    }

    @MainActor
    func testRenameBranchRejectsInvalidName() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.renameBranch("master", to: "bad name")
        guard case .invalidName = result else { return XCTFail("expected invalidName, got \(result)") }
        await store.refreshStatus()
        XCTAssertEqual(store.repo.branch, "master", "nothing should have run")
    }

    @MainActor
    func testRenameBranchRejectsDuplicateName() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["branch", "existing"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.renameBranch("master", to: "existing")
        XCTAssertEqual(result, .duplicateName)
    }

    // MARK: - Delete (local)

    @MainActor
    func testDeleteMergedBranchSucceeds() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["branch", "merged-branch"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let result = await store.deleteBranch("merged-branch")
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.notFullyMerged)
        await store.refreshStatus()
        XCTAssertFalse(store.branches.contains { $0.name == "merged-branch" })
    }

    @MainActor
    func testDeleteUnmergedBranchFailsClassifiedThenForceDeleteSucceeds() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "unmerged"], in: url)
        try TestHelpers.write("x\n", to: url, "x.txt")
        _ = try await git.run(["add", "x.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "unmerged commit"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let result = await store.deleteBranch("unmerged")
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.notFullyMerged, "real git stderr: \(result.error?.stderr ?? "")")
        XCTAssertTrue(result.error?.stderr.localizedCaseInsensitiveContains("not fully merged") ?? false)

        let forced = await store.deleteBranch("unmerged", force: true)
        XCTAssertTrue(forced.succeeded)
        await store.refreshStatus()
        XCTAssertFalse(store.branches.contains { $0.name == "unmerged" })
    }

    // MARK: - Delete (remote)

    @MainActor
    func testDeleteRemoteBranchRemovesItFromTheBareRemote() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        let store = RepositoryStore(url: repo)
        _ = await store.push()
        _ = await store.createBranch("feat/remote-only")
        _ = await store.push()
        await store.refreshStatus()
        XCTAssertTrue(store.branches.contains { $0.name == "origin/feat/remote-only" })

        let deleted = await store.deleteRemoteBranch("feat/remote-only", remote: "origin")
        XCTAssertTrue(deleted)
        await store.refreshStatus()
        XCTAssertFalse(store.branches.contains { $0.name == "origin/feat/remote-only" })

        let remoteRefs = try await git.run(["for-each-ref", "refs/heads", "--format=%(refname)"], in: remote)
        XCTAssertFalse(remoteRefs.contains("feat/remote-only"))
    }

    // MARK: - Preflight

    @MainActor
    func testMergePreflightBlocksOnUncommittedChanges() throws {
        let repo = Repository(id: URL(fileURLWithPath: "/tmp/repo"), branch: "master",
                               changes: [FileChange(path: "a.txt", status: .modified, area: .unstaged)])
        let issues = Preflight.check(.mergeBranch(branch: "feature"), repo: repo, hasUpstream: true)
        XCTAssertTrue(issues.contains { $0.id == "uncommitted" && $0.severity == .blocker })
    }

    @MainActor
    func testMergePreflightBlocksWhenOperationInProgress() throws {
        let repo = Repository(id: URL(fileURLWithPath: "/tmp/repo"), branch: "master")
        let issues = Preflight.check(.mergeBranch(branch: "feature"), repo: repo, hasUpstream: true, operationInProgress: true)
        XCTAssertTrue(issues.contains { $0.id == "operation-in-progress" && $0.severity == .blocker })
    }

    @MainActor
    func testMergePreflightCleanHasNoIssues() throws {
        let repo = Repository(id: URL(fileURLWithPath: "/tmp/repo"), branch: "master")
        XCTAssertEqual(Preflight.check(.mergeBranch(branch: "feature"), repo: repo, hasUpstream: true), [])
    }

    /// A repo-local `core.sshCommand` (an agent can write `.git/config`) runs on a manual fetch —
    /// the user clicked — but never on a background auto-fetch tick.
    @MainActor
    func testAutoFetchSkipsRepoLocalTransportCommand() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let marker = url.appendingPathComponent("ran")
        let script = url.appendingPathComponent("evil.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let git = GitRunner()
        _ = try await git.run(["remote", "add", "origin", "ssh://example.invalid/x.git"], in: url)
        _ = try await git.run(["config", "core.sshCommand", script.path], in: url)
        let store = RepositoryStore(url: url)

        let auto = await store.autoFetch()
        XCTAssertFalse(auto.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        _ = await store.fetch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "setup check: a manual fetch does run it")
    }
}
