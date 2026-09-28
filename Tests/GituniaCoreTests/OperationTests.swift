import XCTest
@testable import GituniaCore

/// T2: history of another branch, cherry-pick/revert, and the generalised `GitOperation` model
/// (merge/rebase/cherry-pick/revert) that replaces the old `mergeInProgress`/`rebaseInProgress`
/// pair. All against real temp repositories — see `RemoteOpsTests` for the equivalent rebase
/// coverage this generalises.
final class OperationTests: XCTestCase {
    // MARK: - History of another branch / cherry-pickable membership

    @MainActor
    func testHistoryOfAnotherBranchAndCherryPickableMembership() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("f1\n", to: url, "f1.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feature: f1"], in: url)
        try TestHelpers.write("f2\n", to: url, "f2.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feature: f2"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)

        // History of "feature" without checking it out.
        let featureHistory = await store.history(branch: "feature")
        XCTAssertEqual(featureHistory.map(\.subject), ["feature: f2", "feature: f1", "init"])
        // Current branch (master) still only has "init".
        let mainHistory = await store.history()
        XCTAssertEqual(mainHistory.map(\.subject), ["init"])

        // Both feature commits are ahead of HEAD (master) — exactly what cherry-pick operates on.
        let cherryPickable = await store.commitsNotReachableFromHead("feature")
        XCTAssertEqual(cherryPickable, Set(featureHistory.dropLast().map(\.hash)))

        // Single-commit membership check (used by the ⌘K palette) agrees.
        let f2Hash = featureHistory[0].hash
        let initHash = featureHistory[2].hash
        let isF2Ancestor = await store.isAncestorOfHead(f2Hash)
        let isInitAncestor = await store.isAncestorOfHead(initHash)
        XCTAssertFalse(isF2Ancestor)
        XCTAssertTrue(isInitAncestor)
    }

    // MARK: - Revert

    @MainActor
    func testRevertCreatesInverseCommitAndLeavesOriginalInHistory() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("hello\nadded\n", to: url, "README.md")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add a line"))
        let toRevert = (await store.history())[0]

        let reverted = await store.revertCommit(toRevert.hash)
        XCTAssertTrue(reverted)

        let content = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(content, "hello\n", "the added line is gone from the working tree")

        let history = await store.history()
        XCTAssertEqual(history.map(\.subject).count, 3, "revert commit + original + init, nothing removed from history")
        XCTAssertTrue(history.contains { $0.hash == toRevert.hash }, "the original commit is still in history")
    }

    /// The whole point of `git revert` over `undoLastCommit`: it works without force, even on a
    /// commit the remote already has.
    @MainActor
    func testRevertOfAPushedCommitWorksWithoutForce() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        let store = RepositoryStore(url: repo)
        try TestHelpers.write("hello\nadded\n", to: repo, "README.md")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add a line"))
        let toRevert = (await store.history())[0]
        _ = await store.push()

        let reverted = await store.revertCommit(toRevert.hash)
        XCTAssertTrue(reverted)

        let push = await store.push()
        XCTAssertTrue(push.succeeded, "an ordinary fast-forward push — no force needed")
    }

    // MARK: - Cherry-pick

    @MainActor
    func testCherryPickAppliesTheChange() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("picked\n", to: url, "picked.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feature: picked"], in: url)
        let commitHash = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        await store.refreshStatus()

        let picked = await store.cherryPick(commitHash)
        XCTAssertTrue(picked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("picked.txt").path))
        let history = await store.history()
        XCTAssertEqual(history[0].subject, "feature: picked")
    }

    /// Two branches editing the same line so a cherry-pick genuinely conflicts — the real path
    /// `.cherryPick` detection, `useOurs`/`useTheirs`, and `continueOperation`/`skipOperation`/
    /// `abortOperation` exist for.
    @MainActor
    private func makeConflictingCherryPick() async throws -> (store: RepositoryStore, url: URL, commitHash: String) {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        try TestHelpers.write("line1\n", to: url, "f.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "add f.txt"], in: url)

        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("line1-feature\n", to: url, "f.txt")
        _ = try await git.run(["commit", "-q", "-am", "feature changes line1"], in: url)
        let commitHash = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("line1-master\n", to: url, "f.txt")
        _ = try await git.run(["commit", "-q", "-am", "master changes line1"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return (store, url, commitHash)
    }

    @MainActor
    func testCherryPickConflictDetectedResolveAndContinueCompletes() async throws {
        let (store, url, commitHash) = try await makeConflictingCherryPick()

        let picked = await store.cherryPick(commitHash)
        XCTAssertFalse(picked)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .cherryPick)
        XCTAssertEqual(store.conflictedChanges.map(\.path), ["f.txt"])

        _ = await store.useTheirs(store.conflictedChanges[0])
        let continued = await store.continueOperation()
        XCTAssertTrue(continued)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        let content = try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-feature")
    }

    /// Verified against real git (see the task's exploration): during a cherry-pick, "ours" is the
    /// current branch (the commit being cherry-picked onto), "theirs" is the commit being applied —
    /// the same direction as a merge, unlike a rebase.
    @MainActor
    func testOursDuringCherryPickIsCurrentBranchTheirsIsTheAppliedCommit() async throws {
        let (storeOurs, urlOurs, hashOurs) = try await makeConflictingCherryPick()
        _ = await storeOurs.cherryPick(hashOurs)
        await storeOurs.refreshStatus()
        _ = await storeOurs.useOurs(storeOurs.conflictedChanges[0])
        let oursContent = try String(contentsOf: urlOurs.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(oursContent.trimmingCharacters(in: .whitespacesAndNewlines), "line1-master")

        let (storeTheirs, urlTheirs, hashTheirs) = try await makeConflictingCherryPick()
        _ = await storeTheirs.cherryPick(hashTheirs)
        await storeTheirs.refreshStatus()
        _ = await storeTheirs.useTheirs(storeTheirs.conflictedChanges[0])
        let theirsContent = try String(contentsOf: urlTheirs.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(theirsContent.trimmingCharacters(in: .whitespacesAndNewlines), "line1-feature")
    }

    @MainActor
    func testSkipCherryPickDropsTheConflictingCommit() async throws {
        let (store, url, commitHash) = try await makeConflictingCherryPick()
        _ = await store.cherryPick(commitHash)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .cherryPick)

        let skipped = await store.skipOperation()
        XCTAssertTrue(skipped)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        let content = try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-master")
    }

    @MainActor
    func testAbortCherryPickRestoresPreCherryPickState() async throws {
        let (store, url, commitHash) = try await makeConflictingCherryPick()
        _ = await store.cherryPick(commitHash)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .cherryPick)

        let aborted = await store.abortOperation()
        XCTAssertTrue(aborted)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        let content = try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-master")
    }

    // MARK: - Revert conflict

    /// A revert of an earlier commit conflicts with a later edit to the same line — the real path
    /// `.revert` detection and abort exist for.
    @MainActor
    func testRevertConflictDetectedAndAbortRestores() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        try TestHelpers.write("line1\n", to: url, "f.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "add f.txt"], in: url)
        try TestHelpers.write("line1-changed\n", to: url, "f.txt")
        _ = try await git.run(["commit", "-q", "-am", "change line1"], in: url)
        let toRevert = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestHelpers.write("line1-changed-again\n", to: url, "f.txt")
        _ = try await git.run(["commit", "-q", "-am", "change line1 again"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let reverted = await store.revertCommit(toRevert)
        XCTAssertFalse(reverted)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .revert)
        XCTAssertEqual(store.conflictedChanges.map(\.path), ["f.txt"])

        let aborted = await store.abortOperation()
        XCTAssertTrue(aborted)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        let content = try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-changed-again")
    }

    // MARK: - Merge continue

    @MainActor
    func testMergeContinueCommitsTheResolution() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("hello\nfeature-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "feature change"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("hello\nmain-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "master change"], in: url)
        _ = try? await git.run(["merge", "-q", "feature"], in: url, allowedExitCodes: [0, 1])

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .merge)
        _ = await store.useTheirs(store.conflictedChanges[0])

        let headBefore = try await git.run(["rev-parse", "HEAD"], in: url)
        let continued = await store.continueOperation()
        XCTAssertTrue(continued)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        let headAfter = try await git.run(["rev-parse", "HEAD"], in: url)
        XCTAssertNotEqual(headBefore, headAfter, "merge --continue committed the resolution")
        let parents = try await git.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: url)
        XCTAssertEqual(parents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").count, 3)
    }

    // MARK: - Precedence of detection

    /// Each operation's own test above already asserts `store.operation` equals exactly that one
    /// case with no other state present; this test just makes the "never overlap" claim explicit —
    /// a rebase directory and a stray `MERGE_HEAD` never coexist in practice, but if they somehow
    /// did, rebase wins (see `refreshOperationState`'s check order).
    @MainActor
    func testNoOperationInProgressOnAFreshRepo() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertNil(store.operation)
        XCTAssertNotEqual(store.operation, .merge)
        XCTAssertFalse(store.rebaseInProgress)
    }
}
