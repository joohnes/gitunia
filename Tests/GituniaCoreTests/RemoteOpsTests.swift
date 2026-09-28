import XCTest
@testable import GituniaCore

final class RemoteOpsTests: XCTestCase {
    /// Creates repo A with a bare remote B added as origin (nothing pushed yet).
    @MainActor
    private func makeRepoWithRemote() async throws -> (repo: URL, remote: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        return (repo, remote)
    }

    @MainActor
    func testPushSetsUpstreamThenTracksAhead() async throws {
        let (url, _) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertFalse(store.hasUpstream)

        let pushed1 = await store.push()          // no upstream → falls back to push -u origin HEAD
        XCTAssertTrue(pushed1.succeeded)
        XCTAssertEqual(pushed1.summary, "Pushed to origin/master")
        XCTAssertTrue(store.hasUpstream)
        XCTAssertEqual(store.repo.ahead, 0)

        try TestHelpers.write("x\n", to: url, "x.txt")
        await store.stageAll()
        let committed = await store.commit(CommitMessage(title: "feat: x"))
        XCTAssertTrue(committed)
        XCTAssertEqual(store.repo.ahead, 1)
        let pushed2 = await store.push()
        XCTAssertTrue(pushed2.succeeded)
        XCTAssertEqual(store.repo.ahead, 0)
        let fetched = await store.fetch()
        XCTAssertTrue(fetched.succeeded)
    }

    /// `git branch -m` keeps `origin/old` as the renamed branch's upstream; the push preflight must
    /// not warn "Nothing to push" (ahead is against `origin/old`), and push must still land `new`.
    @MainActor
    func testPushAfterRenameHasNoNothingToPushWarning() async throws {
        let (url, _) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        _ = await store.createBranch("old")
        let first = await store.push()
        XCTAssertTrue(first.succeeded)
        _ = await store.renameBranch("old", to: "new")
        await store.refreshStatus()
        XCTAssertTrue(store.hasUpstream)
        XCTAssertEqual(store.upstreamBranch, "old")
        XCTAssertFalse(store.upstreamMatchesBranch)

        let issues = Preflight.check(.push, repo: store.repo, hasUpstream: store.hasUpstream && store.upstreamMatchesBranch)
        XCTAssertFalse(issues.contains { $0.id == "nothing-to-push" })

        let pushed = await store.push()
        XCTAssertTrue(pushed.succeeded, pushed.summary)
        XCTAssertEqual(store.upstreamBranch, "new")
        XCTAssertTrue(store.upstreamMatchesBranch)
    }

    @MainActor
    func testPullFastForwards() async throws {
        let (a, remote) = try await makeRepoWithRemote()
        let storeA = RepositoryStore(url: a)
        _ = await storeA.push()

        let cloneDir = try TestHelpers.makeTempDir().appendingPathComponent("clone")
        _ = try await GitRunner().run(["clone", "-q", remote.path, cloneDir.path], in: a)
        let storeC = RepositoryStore(url: cloneDir)
        await storeC.refreshStatus()

        try TestHelpers.write("y\n", to: a, "y.txt")
        await storeA.stageAll()
        _ = await storeA.commit(CommitMessage(title: "feat: y"))
        _ = await storeA.push()

        let fetched2 = await storeC.fetch()
        XCTAssertTrue(fetched2.succeeded)
        XCTAssertEqual(storeC.repo.behind, 1)
        let pulled = await storeC.pull()
        XCTAssertTrue(pulled.succeeded)
        XCTAssertEqual(storeC.repo.behind, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneDir.appendingPathComponent("y.txt").path))
    }

    @MainActor
    func testCheckoutRemoteBranchCreatesTrackingBranch() async throws {
        let (a, remote) = try await makeRepoWithRemote()
        let storeA = RepositoryStore(url: a)
        _ = await storeA.push()
        _ = await storeA.createBranch("feat/remote-only")
        _ = await storeA.push()

        let cloneDir = try TestHelpers.makeTempDir().appendingPathComponent("clone")
        _ = try await GitRunner().run(["clone", "-q", remote.path, cloneDir.path], in: a)
        let storeC = RepositoryStore(url: cloneDir)
        await storeC.refreshStatus()
        let remoteBranch = storeC.branches.first { $0.name == "origin/feat/remote-only" }!
        let checkedOutRemote = await storeC.checkout(remoteBranch)
        XCTAssertTrue(checkedOutRemote)
        XCTAssertEqual(storeC.repo.branch, "feat/remote-only")
        XCTAssertTrue(storeC.hasUpstream)
    }

    @MainActor
    func testCheckoutRemoteBranchWhenLocalExistsSwitchesToLocal() async throws {
        let (url, _) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        _ = await store.push()
        _ = await store.createBranch("feat/dup")
        _ = await store.push()
        let checkedOutMain = await store.checkout(store.branches.first { $0.name == "master" && !$0.isRemote }!)
        XCTAssertTrue(checkedOutMain)

        let remoteDup = store.branches.first { $0.name == "origin/feat/dup" }!
        XCTAssertTrue(store.branches.contains { !$0.isRemote && $0.name == "feat/dup" })
        let checkedOut = await store.checkout(remoteDup)
        XCTAssertTrue(checkedOut)
        XCTAssertEqual(store.repo.branch, "feat/dup")
    }

    @MainActor
    func testPushWithoutRemoteFails() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: repo)
        await store.refreshStatus()

        let pushed = await store.push()
        XCTAssertFalse(pushed.succeeded)
        XCTAssertEqual(pushed.summary, "No remote configured")
        XCTAssertTrue(store.lastError?.stderr.contains("No remote") ?? false)
        XCTAssertEqual(pushed.failureKind, .noRemote)
    }

    /// `hasUpstream` is cached from the last refresh; a branch switched outside the app leaves it
    /// stale, so a plain `git push` fails with "has no upstream branch". Push must retry with
    /// `--set-upstream <remote> <branch>` instead of surfacing that error.
    @MainActor
    func testPushRetriesWithSetUpstreamWhenCachedUpstreamIsStale() async throws {
        let (url, remote) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        _ = await store.push()
        XCTAssertTrue(store.hasUpstream)
        _ = try await GitRunner().run(["switch", "-q", "-c", "feat"], in: url)   // behind the app's back

        let pushed = await store.push()
        XCTAssertTrue(pushed.succeeded, pushed.error?.stderr ?? "")
        let upstream = try await GitRunner().run(["rev-parse", "--abbrev-ref", "feat@{upstream}"], in: url)
        XCTAssertEqual(upstream.trimmingCharacters(in: .whitespacesAndNewlines), "origin/feat")
        let remoteBranches = try await GitRunner().run(["branch", "--list", "feat"], in: remote)
        XCTAssertFalse(remoteBranches.isEmpty)
    }

    /// A branch created tracking `origin/master` — plain `git push` refuses ("does not match the name
    /// of your current branch"); push publishes it under its own name instead.
    @MainActor
    func testPushRetriesWithSetUpstreamWhenUpstreamNameDiffers() async throws {
        let (url, _) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        _ = await store.push()
        _ = try await GitRunner().run(["switch", "-q", "-c", "feat2", "--track", "origin/master"], in: url)
        await store.refreshStatus()
        XCTAssertTrue(store.hasUpstream)

        let pushed = await store.push()
        XCTAssertTrue(pushed.succeeded, pushed.error?.stderr ?? "")
        let upstream = try await GitRunner().run(["rev-parse", "--abbrev-ref", "feat2@{upstream}"], in: url)
        XCTAssertEqual(upstream.trimmingCharacters(in: .whitespacesAndNewlines), "origin/feat2")
    }

    // MARK: - Diverged pull: rebase / merge

    /// Two clones of the same repo commit independent, non-conflicting changes so the second
    /// clone's branch diverges (ahead > 0 && behind > 0) without either `pullRebase`/`pullMerge`
    /// hitting an actual conflict — the conflict path gets its own test below.
    @MainActor
    private func makeDivergedNonConflicting() async throws -> (a: RepositoryStore, b: RepositoryStore) {
        let (aURL, remote) = try await makeRepoWithRemote()
        let storeA = RepositoryStore(url: aURL)
        _ = await storeA.push()

        let bURL = try TestHelpers.makeTempDir().appendingPathComponent("b")
        _ = try await GitRunner().run(["clone", "-q", remote.path, bURL.path], in: aURL)
        let storeB = RepositoryStore(url: bURL)
        await storeB.refreshStatus()

        try TestHelpers.write("a\n", to: aURL, "a.txt")
        await storeA.stageAll()
        _ = await storeA.commit(CommitMessage(title: "a change"))
        _ = await storeA.push()

        try TestHelpers.write("b\n", to: bURL, "b.txt")
        await storeB.stageAll()
        _ = await storeB.commit(CommitMessage(title: "b change"))
        _ = await storeB.fetch()
        XCTAssertTrue(Preflight.isDiverged(repo: storeB.repo))
        return (storeA, storeB)
    }

    @MainActor
    func testPullRebaseSucceedsOnNonConflictingDivergence() async throws {
        let (_, storeB) = try await makeDivergedNonConflicting()
        let result = await storeB.pullRebase()
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(storeB.rebaseInProgress)
        XCTAssertEqual(storeB.repo.ahead, 1)
        XCTAssertEqual(storeB.repo.behind, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeB.url.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeB.url.appendingPathComponent("b.txt").path))
    }

    /// `pull --no-rebase --no-ff` must create an actual merge commit, not silently fast-forward —
    /// checked via the real commit graph (two parents on the new HEAD), not just a success flag.
    @MainActor
    func testPullMergeCreatesAMergeCommit() async throws {
        let (_, storeB) = try await makeDivergedNonConflicting()
        let result = await storeB.pullMerge()
        XCTAssertTrue(result.succeeded)
        let parents = try await GitRunner().run(["rev-list", "--parents", "-n", "1", "HEAD"], in: storeB.url)
        let parentCount = parents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").count
        XCTAssertEqual(parentCount, 3, "HEAD plus two parents means an actual merge commit was made")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeB.url.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeB.url.appendingPathComponent("b.txt").path))
    }

    /// Two clones edit the *same line of the same file*, so rebasing one onto the other's push
    /// conflicts — the real path `continueRebase`/`skipRebase`/`abortRebase` and the ours/theirs
    /// inversion exist for.
    @MainActor
    private func makeConflictingRebase() async throws -> (a: RepositoryStore, b: RepositoryStore) {
        let (aURL, remote) = try await makeRepoWithRemote()
        let storeA = RepositoryStore(url: aURL)
        try TestHelpers.write("line1\n", to: aURL, "f.txt")
        await storeA.stageAll()
        _ = await storeA.commit(CommitMessage(title: "add f.txt"))
        _ = await storeA.push()

        let bURL = try TestHelpers.makeTempDir().appendingPathComponent("b")
        _ = try await GitRunner().run(["clone", "-q", remote.path, bURL.path], in: aURL)
        let storeB = RepositoryStore(url: bURL)
        await storeB.refreshStatus()

        try TestHelpers.write("line1-A\n", to: aURL, "f.txt")
        await storeA.stageAll()
        _ = await storeA.commit(CommitMessage(title: "A changes line1"))
        _ = await storeA.push()

        try TestHelpers.write("line1-B\n", to: bURL, "f.txt")
        await storeB.stageAll()
        _ = await storeB.commit(CommitMessage(title: "B changes line1"))
        _ = await storeB.fetch()
        return (storeA, storeB)
    }

    @MainActor
    func testPullRebaseConflictSetsRebaseInProgressThenResolveAndContinueCompletes() async throws {
        let (_, storeB) = try await makeConflictingRebase()
        let result = await storeB.pullRebase()
        XCTAssertFalse(result.succeeded)
        await storeB.refreshStatus()
        XCTAssertTrue(storeB.rebaseInProgress)
        XCTAssertEqual(storeB.conflictedChanges.map(\.path), ["f.txt"])

        // Resolve by keeping "my commit" (theirs, during a rebase) and continue.
        let change = storeB.conflictedChanges[0]
        _ = await storeB.useTheirs(change)
        let continued = await storeB.continueRebase()
        XCTAssertTrue(continued)
        XCTAssertFalse(storeB.rebaseInProgress)
        let content = try String(contentsOf: storeB.url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-B")
    }

    /// Verifies which side is which during a rebase, against real git behaviour rather than the
    /// doc-comment claim: `--ours` is the upstream commit being rebased onto (HEAD during the
    /// rebase), `--theirs` is the local commit being replayed. This is the inverse of a merge.
    /// `useOurs`/`useTheirs` both end in `git add`, which finalizes resolution and makes a second
    /// `checkout --ours`/`--theirs` on the same path a no-op (verified separately against real
    /// git) — so each side needs its own freshly-conflicted clone, not two calls on one conflict.
    @MainActor
    func testOursDuringRebaseIsTheUpstreamCommit() async throws {
        let (_, storeB) = try await makeConflictingRebase()
        _ = await storeB.pullRebase()
        await storeB.refreshStatus()
        let change = storeB.conflictedChanges[0]

        _ = await storeB.useOurs(change)
        let oursContent = try String(contentsOf: storeB.url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(oursContent.trimmingCharacters(in: .whitespacesAndNewlines), "line1-A", "--ours during a rebase is the upstream commit (A's), not the local one")
    }

    @MainActor
    func testSkipRebaseDropsTheConflictingCommit() async throws {
        let (_, storeB) = try await makeConflictingRebase()
        _ = await storeB.pullRebase()
        await storeB.refreshStatus()
        XCTAssertTrue(storeB.rebaseInProgress)

        let skipped = await storeB.skipRebase()
        XCTAssertTrue(skipped)
        await storeB.refreshStatus()
        XCTAssertFalse(storeB.rebaseInProgress)
        let content = try String(contentsOf: storeB.url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-A", "B's conflicting commit was dropped, leaving A's content")
    }

    @MainActor
    func testAbortRebaseRestoresPreRebaseState() async throws {
        let (_, storeB) = try await makeConflictingRebase()
        _ = await storeB.pullRebase()
        await storeB.refreshStatus()
        XCTAssertTrue(storeB.rebaseInProgress)

        let aborted = await storeB.abortRebase()
        XCTAssertTrue(aborted)
        await storeB.refreshStatus()
        XCTAssertFalse(storeB.rebaseInProgress)
        let content = try String(contentsOf: storeB.url.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "line1-B", "back to B's own pre-rebase commit")
    }

    // MARK: - Force push

    @MainActor
    func testForcePushRefusesWithoutUpstream() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: repo)
        await store.refreshStatus()
        XCTAssertFalse(store.hasUpstream)

        let result = await store.forcePush()
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.summary.localizedCaseInsensitiveContains("no upstream") || result.summary.localizedCaseInsensitiveContains("no remote"))
    }

    /// Amending a commit that's already been pushed makes a normal `push()` fail (non-fast-forward
    /// — the remote has the old, un-amended commit); `forcePush()` succeeds because `--force-with-
    /// lease` only refuses on a *stale* remote-tracking ref, not merely on a rewritten history.
    @MainActor
    func testForcePushSucceedsAfterAmendOfAPushedCommit() async throws {
        let (url, _) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("x\n", to: url, "x.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "feat: x"))
        _ = await store.push()
        XCTAssertTrue(store.hasUpstream)

        try TestHelpers.write("x amended\n", to: url, "x.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "feat: x (amended)"), amend: true)

        let plainPush = await store.push()
        XCTAssertFalse(plainPush.succeeded, "the remote still has the pre-amend commit")
        XCTAssertEqual(plainPush.failureKind, .nonFastForward)

        let forced = await store.forcePush()
        XCTAssertTrue(forced.succeeded)
        XCTAssertEqual(store.repo.ahead, 0)
    }

    /// `--force-with-lease` refuses when the remote moved since this repo's own last fetch, even
    /// though the local branch still has commits ahead of it — the whole point of "with-lease" over
    /// a bare `--force`.
    @MainActor
    func testForcePushRejectedWhenRemoteMovedSinceLastFetch() async throws {
        let (aURL, remote) = try await makeRepoWithRemote()
        let storeA = RepositoryStore(url: aURL)
        _ = await storeA.push()

        let bURL = try TestHelpers.makeTempDir().appendingPathComponent("b")
        _ = try await GitRunner().run(["clone", "-q", remote.path, bURL.path], in: aURL)
        let storeB = RepositoryStore(url: bURL)
        await storeB.refreshStatus()

        // B pushes twice — A's remote-tracking ref (from its own last push) is now stale.
        try TestHelpers.write("b1\n", to: bURL, "b1.txt")
        await storeB.stageAll()
        _ = await storeB.commit(CommitMessage(title: "b1"))
        _ = await storeB.push()
        try TestHelpers.write("b2\n", to: bURL, "b2.txt")
        await storeB.stageAll()
        _ = await storeB.commit(CommitMessage(title: "b2"))
        _ = await storeB.push()

        try TestHelpers.write("a\n", to: aURL, "a.txt")
        await storeA.stageAll()
        _ = await storeA.commit(CommitMessage(title: "a change"))

        let forced = await storeA.forcePush()
        XCTAssertFalse(forced.succeeded)
        XCTAssertEqual(forced.failureKind, .leaseStale)
    }

    /// Under `push.default=matching` a bare `git push --force-with-lease` force-updates *every*
    /// matching branch. Force push must touch exactly one ref — the named branch — and push that
    /// branch even when HEAD has since moved to another one (stale toast / dialog).
    @MainActor
    func testForcePushTouchesOnlyTheNamedBranch() async throws {
        let (url, remote) = try await makeRepoWithRemote()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        _ = await store.push()                                   // master, with upstream
        _ = await store.createBranch("other")
        try TestHelpers.write("o\n", to: url, "o.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "o"))
        _ = await store.push()                                   // other, with upstream
        let otherOnRemote = try await git.run(["rev-parse", "other"], in: remote)
        // Rewrite both branches locally so either would be force-updated by a matching push.
        _ = try await git.run(["reset", "-q", "--hard", "HEAD~1"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        _ = try await git.run(["commit", "-q", "--amend", "--allow-empty", "-m", "master amended"], in: url)
        _ = try await git.run(["config", "push.default", "matching"], in: url)
        _ = try await git.run(["checkout", "-q", "other"], in: url)   // HEAD is no longer master
        await store.refreshStatus()

        let forced = await store.forcePush(branch: "master")
        XCTAssertTrue(forced.succeeded, forced.error?.stderr ?? "")
        let mainLocal = try await git.run(["rev-parse", "master"], in: url)
        let mainRemote = try await git.run(["rev-parse", "master"], in: remote)
        let otherRemote = try await git.run(["rev-parse", "other"], in: remote)
        XCTAssertEqual(mainRemote, mainLocal, "master was force-pushed")
        XCTAssertEqual(otherRemote, otherOnRemote, "other was left alone")
    }
}
