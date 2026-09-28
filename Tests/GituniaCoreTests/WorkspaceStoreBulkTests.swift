import XCTest
@testable import GituniaCore

final class WorkspaceStoreBulkTests: XCTestCase {
    /// Creates a repo with a bare remote added as origin and one commit already pushed,
    /// so `fetch`/`pull` have a real (fast, local) remote to talk to.
    @MainActor
    private func makeConnectedRepo(named name: String, in ws: URL) async throws -> RepositoryStore {
        let repo = try await TestHelpers.makeTempRepo()
        let dest = ws.appendingPathComponent(name)
        try FileManager.default.moveItem(at: repo, to: dest)
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("\(name)-remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: dest)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: dest)
        let store = RepositoryStore(url: dest)
        _ = await store.push()
        return store
    }

    @MainActor
    private func makeStore() throws -> WorkspaceStore {
        WorkspaceStore(configStore: ConfigStore(fileURL: try TestHelpers.makeTempDir().appendingPathComponent("cfg.json")))
    }

    // MARK: - fetchAll / pullAll progress + skipping

    @MainActor
    func testFetchAllReachesTotalOverMultipleRepos() async throws {
        let ws = try TestHelpers.makeTempDir()
        _ = try await makeConnectedRepo(named: "a", in: ws)
        _ = try await makeConnectedRepo(named: "b", in: ws)
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)

        let result = await store.fetchAll()
        XCTAssertEqual(result.kind, .fetch)
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.completed, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(store.bulk, "bulk is cleared once the run finishes")
        store.stopWatching()
    }

    @MainActor
    func testFetchAllSkipsUnavailableRepos() async throws {
        let ws = try TestHelpers.makeTempDir()
        _ = try await makeConnectedRepo(named: "a", in: ws)
        _ = try await makeConnectedRepo(named: "b", in: ws)
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 2)

        // Simulate "b" having vanished from disk between watcher ticks without a rescan yet
        // (a full `refreshAll` would just drop it from `repositories`; this exercises the
        // in-list-but-unavailable state that a live watcher can momentarily produce). Must act
        // on the instance `store.repositories` actually holds, not the standalone one the
        // helper used to push — `openWorkspace`'s scan creates its own `RepositoryStore`.
        let repoB = store.repositories.first { $0.repo.name == "b" }!
        try FileManager.default.removeItem(at: repoB.url)
        await repoB.refreshStatus()
        XCTAssertFalse(repoB.repo.isAvailable)

        let result = await store.fetchAll()
        XCTAssertEqual(result.total, 1, "the unavailable repo shrinks total rather than failing")
        XCTAssertEqual(result.completed, 1)
        XCTAssertTrue(result.failures.isEmpty)
        store.stopWatching()
    }

    @MainActor
    func testPullAllSkipsReposWithoutUpstream() async throws {
        let ws = try TestHelpers.makeTempDir()
        _ = try await makeConnectedRepo(named: "connected", in: ws)
        // A plain repo with no remote at all — never had an upstream to pull from.
        let plain = try await TestHelpers.makeTempRepo()
        try FileManager.default.moveItem(at: plain, to: ws.appendingPathComponent("plain"))
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 2)

        let result = await store.pullAll()
        XCTAssertEqual(result.kind, .pull)
        XCTAssertEqual(result.total, 1, "the repo without an upstream is skipped, not failed")
        XCTAssertEqual(result.completed, 1)
        XCTAssertTrue(result.failures.isEmpty)
        store.stopWatching()
    }

    /// A diverged repo isn't silently excluded the way "no upstream" is — `pull --ff-only` there is
    /// a known dead end, so `pullAll` counts it, never runs `pull` on it (resolving a divergence is
    /// a choice, not something a bulk sweep can make), and reports it by name so the user knows to
    /// come back and pull it individually.
    @MainActor
    func testPullAllSkipsDivergedReposAndReportsThem() async throws {
        let ws = try TestHelpers.makeTempDir()
        let clean = try await makeConnectedRepo(named: "clean", in: ws)

        // "diverged": clone of a repo, then both sides commit independently so ahead > 0 && behind > 0.
        let base = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("diverged-remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: base)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: base)
        _ = await RepositoryStore(url: base).push()

        let divergedDir = ws.appendingPathComponent("diverged")
        _ = try await git.run(["clone", "-q", remote.path, divergedDir.path], in: base)
        _ = try await git.run(["config", "user.email", "test@example.com"], in: divergedDir)
        _ = try await git.run(["config", "user.name", "Test"], in: divergedDir)
        _ = try await git.run(["config", "commit.gpgsign", "false"], in: divergedDir)

        try TestHelpers.write("remote-side\n", to: base, "remote-side.txt")
        _ = try await git.run(["add", "-A"], in: base)
        _ = try await git.run(["commit", "-q", "-m", "remote side"], in: base)
        _ = try await git.run(["push", "-q"], in: base)

        try TestHelpers.write("local-side\n", to: divergedDir, "local-side.txt")
        _ = try await git.run(["add", "-A"], in: divergedDir)
        _ = try await git.run(["commit", "-q", "-m", "local side"], in: divergedDir)
        _ = try await git.run(["fetch", "-q"], in: divergedDir)

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        let divergedStore = store.repositories.first { $0.repo.name == "diverged" }!
        XCTAssertTrue(Preflight.isDiverged(repo: divergedStore.repo), "ahead: \(divergedStore.repo.ahead), behind: \(divergedStore.repo.behind)")

        let result = await store.pullAll()
        XCTAssertEqual(result.total, 2, "both repos count toward the total, even though one is only reported, not pulled")
        XCTAssertEqual(result.completed, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.repo, "diverged")
        XCTAssertEqual(result.failures.first?.message, "Diverged — pull individually")
        // The clean repo was actually pulled (a no-op here, nothing new to fetch from its own push).
        XCTAssertFalse(result.failures.contains { $0.repo == "clean" })
        _ = clean
        store.stopWatching()
    }

    // MARK: - pushAll progress + skipping

    /// Same shape as `makeConnectedRepo`, but never pushes — `origin` is configured, yet there is
    /// no upstream, which is exactly the "first push" situation `pushAll` must not do on its own.
    @MainActor
    private func makeUnpushedRepo(named name: String, in ws: URL) async throws -> (store: RepositoryStore, remote: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let dest = ws.appendingPathComponent(name)
        try FileManager.default.moveItem(at: repo, to: dest)
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("\(name)-remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: dest)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: dest)
        let store = RepositoryStore(url: dest)
        await store.refreshStatus()
        return (store, remote)
    }

    @MainActor
    func testPushAllSkipsRepoWithNoUpstreamAndDoesNotPublishIt() async throws {
        let ws = try TestHelpers.makeTempDir()
        // "ahead" has an upstream and a commit ready to push.
        let ahead = try await makeConnectedRepo(named: "ahead", in: ws)
        try TestHelpers.write("x\n", to: ahead.url, "x.txt")
        await ahead.stageAll()
        _ = await ahead.commit(CommitMessage(title: "feat: x"))
        XCTAssertEqual(ahead.repo.ahead, 1)

        // "fresh" has a remote but was never pushed — no upstream yet.
        let (fresh, freshRemote) = try await makeUnpushedRepo(named: "fresh", in: ws)
        XCTAssertFalse(fresh.hasUpstream)

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 2)

        let result = await store.pushAll()
        XCTAssertEqual(result.kind, .push)
        XCTAssertEqual(result.total, 1, "the repo with no upstream is skipped, not attempted")
        XCTAssertEqual(result.completed, 1)
        XCTAssertTrue(result.failures.isEmpty)

        // The behaviour that actually matters: the bare remote for "fresh" never got a branch.
        let branches = try await GitRunner().run(["branch"], in: freshRemote)
        XCTAssertTrue(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "pushAll must never create the remote branch for a repo with no upstream")
        store.stopWatching()
    }

    @MainActor
    func testPushAllSkipsRepoWithNothingToPush() async throws {
        let ws = try TestHelpers.makeTempDir()
        // Already pushed by makeConnectedRepo — has an upstream, nothing ahead.
        _ = try await makeConnectedRepo(named: "clean", in: ws)
        let ahead = try await makeConnectedRepo(named: "ahead", in: ws)
        try TestHelpers.write("x\n", to: ahead.url, "x.txt")
        await ahead.stageAll()
        _ = await ahead.commit(CommitMessage(title: "feat: x"))

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 2)

        let result = await store.pushAll()
        XCTAssertEqual(result.total, 1, "the repo with nothing to push is skipped")
        XCTAssertEqual(result.completed, 1)
        XCTAssertTrue(result.failures.isEmpty)
        store.stopWatching()
    }

    @MainActor
    func testPushAllCollectsFailureAndContinues() async throws {
        let ws = try TestHelpers.makeTempDir()
        let good = try await makeConnectedRepo(named: "good", in: ws)
        try TestHelpers.write("x\n", to: good.url, "x.txt")
        await good.stageAll()
        _ = await good.commit(CommitMessage(title: "feat: x"))

        // "bad" has an upstream (so it isn't skipped) but its remote no longer exists, so the push fails.
        let bad = try await makeConnectedRepo(named: "bad", in: ws)
        try TestHelpers.write("y\n", to: bad.url, "y.txt")
        await bad.stageAll()
        _ = await bad.commit(CommitMessage(title: "feat: y"))
        _ = try await GitRunner().run(["remote", "set-url", "origin", "/nonexistent/\(UUID().uuidString).git"], in: bad.url)

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 2)

        let result = await store.pushAll()
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.completed, 2, "the failure doesn't abort the rest of the run")
        XCTAssertEqual(result.failures.count, 1)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.repo, "bad")
        XCTAssertFalse(failure.message.isEmpty)
        store.stopWatching()
    }

    /// User decision: force push is never part of Push All — a rejected (non-fast-forward) push in
    /// a bulk run must surface as an ordinary failure, not silently force through.
    @MainActor
    func testPushAllNeverForces() async throws {
        let ws = try TestHelpers.makeTempDir()
        // A clone of the workspace repo pushes first, so the workspace repo's next push is a real
        // non-fast-forward rejection.
        let repoStore = try await makeConnectedRepo(named: "rejected", in: ws)
        let remoteURL = try await GitRunner().run(["remote", "get-url", "origin"], in: repoStore.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cloneDir = try TestHelpers.makeTempDir().appendingPathComponent("clone")
        _ = try await GitRunner().run(["clone", "-q", remoteURL, cloneDir.path], in: repoStore.url)
        _ = try await GitRunner().run(["config", "user.email", "test@example.com"], in: cloneDir)
        _ = try await GitRunner().run(["config", "user.name", "Test"], in: cloneDir)
        _ = try await GitRunner().run(["config", "commit.gpgsign", "false"], in: cloneDir)
        try TestHelpers.write("clone-side\n", to: cloneDir, "clone-side.txt")
        _ = try await GitRunner().run(["add", "-A"], in: cloneDir)
        _ = try await GitRunner().run(["commit", "-q", "-m", "clone side"], in: cloneDir)
        _ = try await GitRunner().run(["push", "-q"], in: cloneDir)

        try TestHelpers.write("x\n", to: repoStore.url, "x.txt")
        await repoStore.stageAll()
        _ = await repoStore.commit(CommitMessage(title: "feat: x"))
        XCTAssertEqual(repoStore.repo.ahead, 1)

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        let result = await store.pushAll()
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.repo, "rejected")
        // The remote still only has the clone's commit — pushAll must not have force-pushed over it.
        let remoteLog = try await GitRunner().run(["log", "--oneline", "-n", "5"], in: cloneDir)
        XCTAssertTrue(remoteLog.contains("clone side"))
        XCTAssertFalse(remoteLog.contains("feat: x"))
        store.stopWatching()
    }

    @MainActor
    func testSecondPushAllIsRefusedWhileOneIsInFlight() async throws {
        let ws = try TestHelpers.makeTempDir()
        let a = try await makeConnectedRepo(named: "a", in: ws)
        try TestHelpers.write("x\n", to: a.url, "x.txt")
        await a.stageAll()
        _ = await a.commit(CommitMessage(title: "feat: x"))
        let b = try await makeConnectedRepo(named: "b", in: ws)
        try TestHelpers.write("y\n", to: b.url, "y.txt")
        await b.stageAll()
        _ = await b.commit(CommitMessage(title: "feat: y"))

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)

        let inFlight = Task { await store.pushAll() }
        await Task.yield()
        XCTAssertNotNil(store.bulk, "the first call should have published its progress by now")

        let refused = await store.pushAll()
        XCTAssertEqual(refused.total, store.bulk?.total ?? -1)
        XCTAssertFalse(refused.completed >= refused.total || store.bulk == nil, "refusal returns the still-running operation, not a fresh one")

        let finished = await inFlight.value
        XCTAssertEqual(finished.completed, finished.total)
        XCTAssertNil(store.bulk)
        store.stopWatching()
    }

    // MARK: - Failure collection

    @MainActor
    func testFetchAllCollectsFailureAndContinues() async throws {
        let ws = try TestHelpers.makeTempDir()
        _ = try await makeConnectedRepo(named: "good", in: ws)

        // "bad" points its origin at a path that doesn't exist, so fetch fails.
        let bad = try await TestHelpers.makeTempRepo()
        let badDest = ws.appendingPathComponent("bad")
        try FileManager.default.moveItem(at: bad, to: badDest)
        _ = try await GitRunner().run(["remote", "add", "origin", "/nonexistent/\(UUID().uuidString).git"], in: badDest)

        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 2)

        let result = await store.fetchAll()
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.completed, 2, "the failure doesn't abort the rest of the run")
        XCTAssertEqual(result.failures.count, 1)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.repo, "bad")
        XCTAssertFalse(failure.message.isEmpty)
        store.stopWatching()
    }

    // MARK: - Refusal to overlap

    @MainActor
    func testSecondBulkOperationIsRefusedWhileOneIsInFlight() async throws {
        let ws = try TestHelpers.makeTempDir()
        _ = try await makeConnectedRepo(named: "a", in: ws)
        _ = try await makeConnectedRepo(named: "b", in: ws)
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)

        let inFlight = Task { await store.fetchAll() }
        await Task.yield() // let the task start and reach its first real suspension (subprocess spawn)
        XCTAssertNotNil(store.bulk, "the first call should have published its progress by now")

        let refused = await store.fetchAll()
        XCTAssertEqual(refused.total, store.bulk?.total ?? -1)
        XCTAssertFalse(refused.completed >= refused.total || store.bulk == nil, "refusal returns the still-running operation, not a fresh one")

        let finished = await inFlight.value
        XCTAssertEqual(finished.completed, finished.total)
        XCTAssertNil(store.bulk)
        store.stopWatching()
    }

    /// Regression test for the auto-fetch/user-action race: a silent sweep (what the background
    /// auto-fetch timer runs) must not start a second sweep over the same repos while one is
    /// already in flight — concurrent git invocations on one repo can collide on git's lock file.
    /// `silent: true` never publishes `store.bulk`, so this checks the returned totals instead of
    /// `store.bulk` the way `testSecondBulkOperationIsRefusedWhileOneIsInFlight` does.
    @MainActor
    func testConcurrentSilentFetchAllDoesNotOverlap() async throws {
        let ws = try TestHelpers.makeTempDir()
        _ = try await makeConnectedRepo(named: "a", in: ws)
        _ = try await makeConnectedRepo(named: "b", in: ws)
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)

        let inFlight = Task { await store.fetchAll(silent: true) }
        await Task.yield() // let the first sweep start and reach its first real suspension

        let second = await store.fetchAll(silent: true)
        XCTAssertEqual(second.total, 0, "a silent sweep that finds one already in flight skips this tick")
        XCTAssertTrue(second.failures.isEmpty)

        let first = await inFlight.value
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(first.completed, 2)
        store.stopWatching()
    }

    // MARK: - Bounded concurrency (C15)

    /// `runBulk` chunks repos 8-at-a-time instead of running them one after another — 10 repos with
    /// a 200ms fake action would take 2s sequentially; chunked (8 + 2) it's ~2 waves, comfortably
    /// under 1.2s. Also checks `completed` reaches `total` and failures stay in sidebar order.
    @MainActor
    func testRunBulkOverlapsWithinAChunk() async throws {
        let ws = try TestHelpers.makeTempDir()
        for i in 0..<10 {
            try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: ws.appendingPathComponent("r\(i)"))
        }
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 10)

        let start = ContinuousClock.now
        let op = await store.runBulk(.fetch, silent: false, skip: { _ in false }) { repo in
            try? await Task.sleep(for: .milliseconds(200))
            // Odd-indexed repos (by sidebar order) fail, to check stable-order failure collection.
            let index = store.repositories.firstIndex { $0 === repo } ?? 0
            return index % 2 == 1
                ? RemoteResult(kind: .fetch, succeeded: false, summary: "boom")
                : RemoteResult(kind: .fetch, succeeded: true, summary: "ok")
        }
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(op.total, 10)
        XCTAssertEqual(op.completed, 10)
        XCTAssertLessThan(elapsed, .milliseconds(1200), "10 repos at 200ms each should overlap in chunks of 8, not run sequentially")
        let expectedFailedNames = store.repositories.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.repo.name }
        XCTAssertEqual(op.failures.map(\.repo), expectedFailedNames, "failures stay in sidebar order")
        store.stopWatching()
    }

    // MARK: - Auto-fetch

    func testAutoFetchIntervalArithmetic() {
        XCTAssertEqual(WorkspaceStore.autoFetchInterval(minutes: 15), .seconds(900))
        XCTAssertEqual(WorkspaceStore.autoFetchInterval(minutes: 1), .seconds(60))
        XCTAssertEqual(WorkspaceStore.autoFetchInterval(minutes: 0), .seconds(0))
        XCTAssertEqual(WorkspaceStore.autoFetchInterval(minutes: -5), .seconds(0), "never a negative sleep")
    }

    // MARK: - stashAll

    @MainActor
    func testStashAllStashesOnlyChangedRepos() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["a", "b", "clean"] {
            try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: ws.appendingPathComponent(name))
        }
        try TestHelpers.write("edited\n", to: ws.appendingPathComponent("a"), "README.md")
        try TestHelpers.write("new\n", to: ws.appendingPathComponent("b"), "untracked.txt")
        let store = try makeStore()
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.count, 3)

        let result = await store.stashAll()
        XCTAssertEqual(result.kind, .stash)
        XCTAssertEqual(result.total, 2)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        for repo in store.repositories {
            let stashes = try await GitRunner().run(["stash", "list"], in: repo.url)
            XCTAssertEqual(stashes.isEmpty, repo.repo.name == "clean", repo.repo.name)
            XCTAssertFalse(repo.repo.hasChanges, repo.repo.name)
        }
        store.stopWatching()
    }
}
