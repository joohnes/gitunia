import XCTest
@testable import GituniaCore

/// Rebase-onto and the fuller stash, all against real temp repositories (git 2.50.1 behaviour is
/// documented on the types in `RepositoryStore+RebaseStash.swift`).
final class RebaseStashTests: XCTestCase {
    private let git = GitRunner()

    @MainActor private func commit(_ url: URL, _ file: String, _ text: String, _ message: String) async throws {
        try TestHelpers.write(text, to: url, file)
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", message], in: url)
    }

    /// master: init → main1 (m.txt). feature: init → feat1 (f.txt), checked out.
    @MainActor private func makeDivergedRepo(conflicting: Bool = false) async throws -> URL {
        let url = try await TestHelpers.makeTempRepo()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try await commit(url, conflicting ? "README.md" : "f.txt", "feature\n", "feat1")
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try await commit(url, conflicting ? "README.md" : "m.txt", "master\n", "main1")
        _ = try await git.run(["checkout", "-q", "feature"], in: url)
        return url
    }

    // MARK: - Rebase

    @MainActor
    func testCleanRebaseReplaysCommitsOnTop() async throws {
        let url = try await makeDivergedRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let oldHash = (await store.history())[0].hash

        let plan = await store.rebasePlan(onto: "master")
        XCTAssertEqual(plan.replayCount, 1)
        XCTAssertEqual(plan.newOnOnto, 1)
        XCTAssertEqual(plan.pushedCount, 0)
        XCTAssertFalse(plan.isUpToDate)

        let outcome = await store.rebase(onto: "master")
        XCTAssertEqual(outcome, .rebased(autostashConflicted: false))
        let history = await store.history()
        XCTAssertEqual(history.map(\.subject), ["feat1", "main1", "init"])
        XCTAssertNotEqual(history[0].hash, oldHash, "replayed commit gets a new hash")
        XCTAssertNil(store.operation)
        XCTAssertNil(store.lastError)

        let again = await store.rebasePlan(onto: "master")
        XCTAssertTrue(again.isUpToDate)
    }

    @MainActor
    func testConflictingRebaseStopsThenContinueFinishes() async throws {
        let url = try await makeDivergedRepo(conflicting: true)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let outcome = await store.rebase(onto: "master")
        XCTAssertEqual(outcome, .stoppedOnConflicts)
        XCTAssertEqual(store.operation, .rebase)
        XCTAssertNil(store.lastError, "conflicts go to the operation banner, not an error toast")
        XCTAssertEqual(store.conflictedChanges.map(\.path), ["README.md"])

        // During a rebase "theirs" is the commit being replayed (ours/theirs inverted).
        await store.useTheirs(store.conflictedChanges[0])
        let continued = await store.continueOperation()
        XCTAssertTrue(continued)
        XCTAssertNil(store.operation)
        let fetched = await store.history()
        XCTAssertEqual(fetched.map(\.subject), ["feat1", "main1", "init"])
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8), "feature\n")
    }

    @MainActor
    func testConflictingRebaseAbortRestoresBranch() async throws {
        let url = try await makeDivergedRepo(conflicting: true)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let before = (await store.history())[0].hash

        _ = await store.rebase(onto: "master")
        XCTAssertEqual(store.operation, .rebase)
        let aborted = await store.abortOperation()
        XCTAssertTrue(aborted)
        XCTAssertNil(store.operation)
        let fetched = await store.history()
        XCTAssertEqual(fetched[0].hash, before)
        XCTAssertEqual(store.repo.branch, "feature")
    }

    @MainActor
    func testRebaseWithAutostashKeepsUncommittedChanges() async throws {
        let url = try await makeDivergedRepo()
        try TestHelpers.write("hello\nlocal edit\n", to: url, "README.md")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let plan = await store.rebasePlan(onto: "master")
        XCTAssertEqual(plan.dirtyCount, 1)

        let outcome = await store.rebase(onto: "master", autostash: true)
        XCTAssertEqual(outcome, .rebased(autostashConflicted: false))
        XCTAssertEqual(store.repo.changes.map(\.path), ["README.md"])
        let fetched = await store.history()
        XCTAssertEqual(fetched.map(\.subject), ["feat1", "main1", "init"])
        let stashes = await store.stashItems()
        XCTAssertTrue(stashes.isEmpty)
    }

    @MainActor
    func testRebaseRefusedWithDirtyTreeWithoutAutostash() async throws {
        let url = try await makeDivergedRepo()
        try TestHelpers.write("hello\nlocal edit\n", to: url, "README.md")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let outcome = await store.rebase(onto: "master")
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(store.operation)
        XCTAssertTrue(store.lastError?.stderr.contains("cannot rebase") ?? false)
    }

    @MainActor
    func testRebasePlanCountsPushedCommits() async throws {
        let url = try await makeDivergedRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: url)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: url)
        _ = try await git.run(["push", "-q", "-u", "origin", "feature"], in: url)
        try await commit(url, "g.txt", "g\n", "feat2 (local only)")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let plan = await store.rebasePlan(onto: "master")
        XCTAssertEqual(plan.replayCount, 2)
        XCTAssertEqual(plan.pushedCount, 1)
        XCTAssertTrue(plan.confirmMessage.contains("1 of them are already pushed"))
        XCTAssertTrue(plan.confirmMessage.contains("force push"))
    }

    // MARK: - Stash list / show

    @MainActor
    func testStashShowIncludesUntrackedFiles() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("hello\nmore\n", to: url, "README.md")
        try TestHelpers.write("new\n", to: url, "untracked.txt")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let stashed = await store.stash(message: "with untracked")
        XCTAssertTrue(stashed)

        let items = await store.stashItems()
        XCTAssertEqual(items.map(\.entry.message), ["with untracked"])
        XCTAssertEqual(items[0].entry.branch, "master")
        XCTAssertLessThan(abs(items[0].date.timeIntervalSinceNow), 120)
        let files = await store.stashDiff(items[0])
        XCTAssertEqual(files.map(\.path).sorted(), ["README.md", "untracked.txt"])
        XCTAssertEqual(files.first { $0.path == "untracked.txt" }?.hunks.first?.lines.contains { $0.text == "new" }, true)
    }

    // MARK: - Apply / pop / drop a chosen entry

    @MainActor
    func testApplyKeepsEntryPopRemovesItDropDeletesChosen() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = await store.stash(message: "first")
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = await store.stash(message: "second")
        var items = await store.stashItems()
        XCTAssertEqual(items.map(\.entry.message), ["second", "first"])

        // Apply the *older* entry (stash@{1}), keeping it.
        let applied = await store.stashApply(items[1], pop: false)
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(store.repo.changes.map(\.path), ["a.txt"])
        XCTAssertEqual(store.stashCount, 2)

        // Drop the newer one; the older one survives.
        let dropped = await store.stashDrop(items[0])
        XCTAssertTrue(dropped)
        items = await store.stashItems()
        XCTAssertEqual(items.map(\.entry.message), ["first"])

        // Pop it after discarding the applied copy.
        try FileManager.default.removeItem(at: url.appendingPathComponent("a.txt"))
        let popped = await store.stashApply(items[0], pop: true)
        XCTAssertEqual(popped, .applied)
        XCTAssertEqual(store.stashCount, 0)
        XCTAssertEqual(store.repo.changes.map(\.path), ["a.txt"])
    }

    @MainActor
    func testStaleStashIndexIsRefused() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = await store.stash(message: "mine")
        let listed = await store.stashItems()
        // Something else stashes meanwhile: "mine" moves to stash@{1}.
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = try await git.run(["stash", "push", "-u", "-m", "agent"], in: url)

        let dropped = await store.stashDrop(listed[0])
        XCTAssertFalse(dropped)
        XCTAssertNotNil(store.lastError)
        let fetched = await store.stashItems()
        XCTAssertEqual(fetched.map(\.entry.message), ["agent", "mine"])
    }

    @MainActor
    func testConflictingPopReportsConflictsAndKeepsEntry() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("stashed\n", to: url, "README.md")
        _ = await store.stash(message: "one")
        try await commit(url, "README.md", "committed\n", "c2")
        await store.refreshStatus()
        let item = (await store.stashItems())[0]

        let outcome = await store.stashApply(item, pop: true)
        XCTAssertEqual(outcome, .conflicts(1))
        XCTAssertNil(store.lastError, "UI reports conflicts itself, never as success or a raw error")
        XCTAssertNil(store.operation, "no operation file is written for a stash conflict")
        XCTAssertEqual(store.conflictedChanges.map(\.path), ["README.md"])
        XCTAssertEqual(store.stashCount, 1, "git keeps the entry when pop conflicts")

        // No operation, yet ours/theirs still resolve it: ours = HEAD ("Keep Current"),
        // theirs = the stash ("Keep Stashed").
        let resolved = await store.useTheirs(store.conflictedChanges[0])
        XCTAssertTrue(resolved)
        XCTAssertTrue(store.conflictedChanges.isEmpty)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8), "stashed\n")
    }

    @MainActor
    func testApplyOverDirtyFileFailsWithError() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("stashed\n", to: url, "README.md")
        _ = await store.stash(message: "one")
        try TestHelpers.write("dirty\n", to: url, "README.md")
        await store.refreshStatus()
        let outcome = await store.stashApply((await store.stashItems())[0], pop: false)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(store.lastError?.stderr.contains("would be overwritten") ?? false)
    }

    // MARK: - Stash selected files

    @MainActor
    func testStashSelectedFilesIncludesOnlySelectedUntracked() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("hello\nedit\n", to: url, "README.md")
        try TestHelpers.write("u\n", to: url, "u.txt")
        try TestHelpers.write("w\n", to: url, "w.txt")
        try TestHelpers.write("x\n", to: url, "a[1].txt")
        try TestHelpers.write("y\n", to: url, "a1.txt")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let outcome = await store.stashFiles(["README.md", "u.txt", "a[1].txt"], message: "picked")
        XCTAssertEqual(outcome, .stashed)
        XCTAssertEqual(store.repo.changes.map(\.path).sorted(), ["a1.txt", "w.txt"], "literal pathspec: a[1].txt must not match a1.txt")
        let item = (await store.stashItems())[0]
        XCTAssertEqual(item.entry.message, "picked")
        let fetched = await store.stashDiff(item)
        XCTAssertEqual(fetched.map(\.path).sorted(), ["README.md", "a[1].txt", "u.txt"])
    }

    @MainActor
    func testStashSelectedRefusesWhenOtherFilesAreStaged() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("a\n", to: url, "a.txt")
        try TestHelpers.write("hello\nstaged\n", to: url, "README.md")
        _ = try await git.run(["add", "README.md"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let outcome = await store.stashFiles(["a.txt"])
        XCTAssertEqual(outcome, .otherFilesStaged(["README.md"]))
        XCTAssertEqual(store.stashCount, 0)
        XCTAssertEqual(store.repo.changes.count, 2, "nothing touched")
    }

    // MARK: - Gitunia-labelled stashes

    @MainActor
    func testAutoStashTakesTrackedAndUntrackedUnderItsLabel() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("hello\nchanged\n", to: url, "README.md")
        try TestHelpers.write("new\n", to: url, "u.txt")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let label = store.stashLabel(for: "master")
        let stashed = await store.autoStash()
        XCTAssertTrue(stashed)
        XCTAssertTrue(store.repo.changes.isEmpty, "tracked and untracked both stashed")
        let list = try await git.run(["stash", "list"], in: url)
        XCTAssertTrue(list.contains(label), list)
        let ours = await store.gituniaStashes()
        let item = try XCTUnwrap(ours.first)
        XCTAssertEqual(item.gituniaLabel?.branch, "master")
        let files = await store.stashFileCount(item)
        XCTAssertEqual(files, 2)
    }

    @MainActor
    func testGituniaStashesExcludeManualStashes() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("one\n", to: url, "a.txt")
        await store.refreshStatus()
        var ok = await store.autoStash()
        XCTAssertTrue(ok)
        try TestHelpers.write("two\n", to: url, "b.txt")
        await store.refreshStatus()
        ok = await store.stash(message: "by hand")
        XCTAssertTrue(ok)

        let all = await store.stashItems()
        XCTAssertEqual(all.count, 2)
        let ours = await store.gituniaStashes()
        XCTAssertEqual(ours.count, 1)
        XCTAssertEqual(ours[0].entry.index, 1)
    }

    @MainActor
    func testGituniaStashRestoresOnAnotherBranch() async throws {
        let url = try await TestHelpers.makeTempRepo()
        _ = try await git.run(["branch", "other"], in: url)
        try TestHelpers.write("agent work\n", to: url, "w.txt")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let stashed = await store.autoStash()
        XCTAssertTrue(stashed)
        _ = try await git.run(["checkout", "-q", "other"], in: url)
        await store.refreshStatus()

        let found = await store.gituniaStashes()
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.gituniaLabel?.branch, "master")
        let outcome = await store.stashApply(item, pop: true)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(store.repo.branch, "other")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("w.txt"), encoding: .utf8), "agent work\n")
        let left = await store.gituniaStashes()
        XCTAssertTrue(left.isEmpty, "popped")
    }
}
