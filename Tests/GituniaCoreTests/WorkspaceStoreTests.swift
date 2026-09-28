import XCTest
@testable import GituniaCore

final class WorkspaceStoreTests: XCTestCase {
    func testRelevantPathsFiltersGitInternals() {
        let paths = [
            "/ws/a/src/master.swift",
            "/ws/a/.git/objects/ab/cd",
            "/ws/a/.git/index",
            "/ws/a/.git/HEAD",
            "/ws/a/.git/refs/heads/master",
            "/ws/a/.git/logs/HEAD",
        ]
        XCTAssertEqual(WorkspaceStore.relevantPaths(paths), [
            "/ws/a/src/master.swift", "/ws/a/.git/index", "/ws/a/.git/HEAD", "/ws/a/.git/refs/heads/master",
        ])
    }

    func testRepositoryOwningPathUsesLongestPrefix() {
        let roots = [URL(fileURLWithPath: "/ws/a"), URL(fileURLWithPath: "/ws/a-b"), URL(fileURLWithPath: "/ws/a/inner")]
        XCTAssertEqual(WorkspaceStore.repository(owning: "/ws/a-b/x.txt", among: roots)?.path, "/ws/a-b")
        XCTAssertEqual(WorkspaceStore.repository(owning: "/ws/a/inner/y.txt", among: roots)?.path, "/ws/a/inner")
        XCTAssertEqual(WorkspaceStore.repository(owning: "/ws/a/z.txt", among: roots)?.path, "/ws/a")
        XCTAssertNil(WorkspaceStore.repository(owning: "/elsewhere/q", among: roots))
    }

    // MARK: - H2: linked worktrees

    /// A linked worktree's HEAD/index/refs live under `.git/worktrees/<name>/` one level deeper
    /// than the plain HEAD/index/refs shape — `relevantPaths` must not drop them as noise.
    func testRelevantPathsAcceptsLinkedWorktreeShapes() {
        let paths = [
            "/ws/master/.git/worktrees/feature/HEAD",
            "/ws/master/.git/worktrees/feature/index",
            "/ws/master/.git/worktrees/feature/refs/bisect/bad",
            "/ws/master/.git/worktrees/feature/ORIG_HEAD", // not one of the three — still noise
            "/ws/master/.git/worktrees/feature", // no filename at all
        ]
        XCTAssertEqual(WorkspaceStore.relevantPaths(paths), [
            "/ws/master/.git/worktrees/feature/HEAD",
            "/ws/master/.git/worktrees/feature/index",
            "/ws/master/.git/worktrees/feature/refs/bisect/bad",
        ])
    }

    /// End-to-end with a real `git worktree add`: a commit made inside the worktree touches
    /// `<master>/.git/worktrees/<name>/{HEAD,index}` — verify the pure mapping functions route those
    /// paths to the worktree's `RepositoryStore`, not the master one, using each repo's real resolved
    /// gitdir (`RepositoryStore.gitDirURL()`).
    @MainActor
    func testWorktreeCommitPathsMapToWorktreeRepoNotMainRepo() async throws {
        let master = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let worktreePath = master.appendingPathComponent(".claude/worktrees/feature").path
        _ = try await git.run(["worktree", "add", "-q", "-b", "feature", worktreePath], in: master)
        let worktree = URL(fileURLWithPath: worktreePath)

        let mainStore = RepositoryStore(url: master)
        let worktreeStore = RepositoryStore(url: worktree)
        let roots = [master, worktree]
        var gitDirs: [URL: URL] = [:]
        if let g = mainStore.gitDirURL() { gitDirs[master] = g }
        if let g = worktreeStore.gitDirURL() { gitDirs[worktree] = g }
        XCTAssertEqual(gitDirs[worktree]?.path, master.appendingPathComponent(".git/worktrees/feature").standardizedFileURL.path)

        try TestHelpers.write("from worktree\n", to: worktree, "wt.txt")
        _ = try await git.run(["add", "wt.txt"], in: worktree)
        _ = try await git.run(["commit", "-q", "-m", "wt commit"], in: worktree)

        let headPath = master.appendingPathComponent(".git/worktrees/feature/HEAD").path
        let indexPath = master.appendingPathComponent(".git/worktrees/feature/index").path
        XCTAssertEqual(WorkspaceStore.repository(owning: headPath, among: roots, gitDirs: gitDirs)?.path, worktree.path)
        XCTAssertEqual(WorkspaceStore.repository(owning: indexPath, among: roots, gitDirs: gitDirs)?.path, worktree.path)
        XCTAssertEqual(WorkspaceStore.relevantPaths([headPath, indexPath]).count, 2)
    }

    /// A worktree an agent put inside the master repo (`<master>/.claude/worktrees/x`) knows its parent
    /// and nests right after it; once removed, `rescanFolder(containing:)` drops it.
    @MainActor
    func testWorktreeNestsUnderParentAndRescanDropsIt() async throws {
        let ws = try TestHelpers.makeTempDir()
        let master = ws.appendingPathComponent("master")
        try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: master)
        for name in ["aaa", "zzz"] {
            try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: ws.appendingPathComponent(name))
        }
        let git = GitRunner()
        let wtPath = master.appendingPathComponent(".claude/worktrees/x").path
        _ = try await git.run(["worktree", "add", "-q", "-b", "x", wtPath], in: master)

        let store = WorkspaceStore(configStore: ConfigStore(fileURL: try TestHelpers.makeTempDir().appendingPathComponent("c.json")))
        await store.openUntitled(linkingFolder: ws)
        store.stopWatching()
        await store.refreshAll()
        let mainStore = try XCTUnwrap(store.repositories.first { $0.repo.name == "master" })
        let wtStore = try XCTUnwrap(store.repositories.first { $0.repo.name == "x" })
        XCTAssertEqual(wtStore.worktreeParent?.path, mainStore.url.resolvingSymlinksInPath().path)
        XCTAssertNil(mainStore.worktreeParent)
        let order = WorkspaceStore.sidebarOrder(store.visibleRepositories)
        // Default sort is changed-first, and `master` is changed (untracked `.claude/`).
        XCTAssertEqual(order.map(\.repo.repo.name), ["master", "x", "aaa", "zzz"])
        XCTAssertEqual(order.map(\.depth), [0, 1, 0, 0])
        // Parent filtered out → the worktree shows top-level.
        XCTAssertEqual(WorkspaceStore.sidebarOrder([wtStore]).map(\.depth), [0])

        _ = try await git.run(["worktree", "remove", wtPath], in: master)
        await store.rescanFolder(containing: mainStore.url)
        XCTAssertEqual(store.repositories.map(\.repo.name).sorted(), ["aaa", "master", "zzz"])
    }

    @MainActor
    func testOpenWorkspaceScansAndPersists() async throws {
        let ws = try TestHelpers.makeTempDir()
        let repoA = try await TestHelpers.makeTempRepo()
        let dest = ws.appendingPathComponent("a")
        try FileManager.default.moveItem(at: repoA, to: dest)
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("cfg.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.map(\.repo.name), ["a"])
        XCTAssertEqual(store.repositories[0].repo.branch, "master")
        XCTAssertEqual(try WorkspaceFile.load(from: XCTUnwrap(store.fileURL)).folders.map(\.path), [ws.standardizedFileURL.path])
        store.stopWatching()
    }

    @MainActor
    func testRefreshAllPicksUpNewAndRemovedRepos() async throws {
        let ws = try TestHelpers.makeTempDir()
        let repoA = try await TestHelpers.makeTempRepo()
        let destA = ws.appendingPathComponent("a")
        try FileManager.default.moveItem(at: repoA, to: destA)
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("cfg.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.map(\.repo.name), ["a"])

        let repoB = try await TestHelpers.makeTempRepo()
        let destB = ws.appendingPathComponent("b")
        try FileManager.default.moveItem(at: repoB, to: destB)
        try FileManager.default.removeItem(at: destA)

        await store.refreshAll()
        XCTAssertEqual(store.repositories.map(\.repo.name), ["b"])
        store.stopWatching()
    }

    @MainActor
    func testRefreshAllPreservesPrefsWhenScanFindsNothing() async throws {
        let ws = try TestHelpers.makeTempDir()
        let repoA = try await TestHelpers.makeTempRepo()
        let dest = ws.appendingPathComponent("a")
        try FileManager.default.moveItem(at: repoA, to: dest)
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("cfg.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store.openUntitled(linkingFolder: ws)
        let repo = store.repositories[0]
        let key = repo.url.path
        store.setTags(["work"], for: repo)
        store.setLocalAIOnly(true, for: repo)

        let movedAway = ws.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: ws, to: movedAway)
        await store.refreshAll()
        XCTAssertEqual(store.file.tags[repo.url.standardizedFileURL.path], ["work"])
        XCTAssertEqual(store.config.repos[key]?.localAIOnly, true)

        try FileManager.default.moveItem(at: movedAway, to: ws)
        await store.refreshAll()
        let reappeared = store.repositories.first { $0.url.path == key }
        XCTAssertEqual(reappeared?.repo.tags, ["work"])
        XCTAssertEqual(reappeared?.repo.localAIOnly, true)
        store.stopWatching()
    }

    @MainActor
    private func makeOpenedStore() async throws -> (WorkspaceStore, RepositoryStore, URL) {
        let ws = try TestHelpers.makeTempDir()
        let repoA = try await TestHelpers.makeTempRepo()
        try FileManager.default.moveItem(at: repoA, to: ws.appendingPathComponent("a"))
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("cfg.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL), draftDebounce: .milliseconds(20))
        await store.openUntitled(linkingFolder: ws)
        return (store, store.repositories[0], cfgURL)
    }

    /// C4: `restoredDraft` is the in-memory hint the view re-reads when a tab/repo is reselected —
    /// it must reflect the latest typed draft immediately, not only once the debounced disk write
    /// (tested above) has fired. Reading it back *before* the debounce elapses is exactly the "switch
    /// tab and come back" case that was broken.
    @MainActor
    func testSetCommitDraftUpdatesRestoredDraftImmediately() async throws {
        let (store, repo, _) = try await makeOpenedStore()
        XCTAssertNil(repo.restoredDraft)
        store.setCommitDraft(CommitMessage(title: "typed just now"), for: repo)
        // No sleep at all: the debounce (>= 1s by default, shorter in this helper) hasn't fired yet.
        XCTAssertEqual(repo.restoredDraft, CommitMessage(title: "typed just now"))
        store.stopWatching()
    }

    @MainActor
    func testStopWatchingFlushesPendingDraftWrite() async throws {
        let (store, repo, cfgURL) = try await makeOpenedStore()
        store.setCommitDraft(CommitMessage(title: "not yet flushed"), for: repo)
        // Stop immediately, well before the debounce interval elapses.
        store.stopWatching()
        XCTAssertEqual(
            ConfigStore(fileURL: cfgURL).loadWithWarning().0.repos[repo.url.path]?.commitDraft,
            CommitMessage(title: "not yet flushed")
        )
    }

    // MARK: - Scope / sort / query (sidebar header redesign)

    @MainActor
    func testScopeFiltersToChangedIncludingAheadOnly() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["dirty", "clean"] {
            let r = try await TestHelpers.makeTempRepo()
            try FileManager.default.moveItem(at: r, to: ws.appendingPathComponent(name))
        }
        try TestHelpers.write("x\n", to: ws.appendingPathComponent("dirty"), "d.txt")

        // "ahead-only" needs an upstream (via a real bare remote) for `git status` to report
        // ahead/behind at all — a plain unpushed repo has no tracking branch to compare against.
        let aheadDest = ws.appendingPathComponent("ahead-only")
        try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: aheadDest)
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("ahead-only-remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: aheadDest)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: aheadDest)
        let aheadStore = RepositoryStore(url: aheadDest)
        _ = await aheadStore.push() // establishes upstream, nothing ahead yet
        try TestHelpers.write("y\n", to: aheadDest, "y.txt")
        await aheadStore.stageAll()
        _ = await aheadStore.commit(CommitMessage(title: "second")) // ahead=1, no working-tree changes

        let store = WorkspaceStore(configStore: ConfigStore(fileURL: try TestHelpers.makeTempDir().appendingPathComponent("c.json")))
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.repositories.first { $0.repo.name == "ahead-only" }?.repo.ahead, 1)

        store.scope = .changed
        XCTAssertEqual(Set(store.visibleRepositories.map(\.repo.name)), ["dirty", "ahead-only"])
        store.stopWatching()
    }

    @MainActor
    func testAttentionScopeIncludesRepoStoppedOnMergeConflict() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["conflicted", "dirty"] {
            try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: ws.appendingPathComponent(name))
        }
        try TestHelpers.write("x\n", to: ws.appendingPathComponent("dirty"), "x.txt")
        let url = ws.appendingPathComponent("conflicted")
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("hello\nfeature-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "feature change"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("hello\nmain-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "master change"], in: url)
        _ = try? await git.run(["merge", "-q", "feature"], in: url, allowedExitCodes: [0, 1])

        let store = WorkspaceStore(configStore: ConfigStore(fileURL: try TestHelpers.makeTempDir().appendingPathComponent("c.json")))
        await store.openUntitled(linkingFolder: ws)
        XCTAssertEqual(store.scopeChips.first { $0.scope == .attention }?.count, 1)
        store.scope = .attention
        XCTAssertEqual(store.visibleRepositories.map(\.repo.name), ["conflicted"])
        XCTAssertEqual(store.visibleRepositories.first?.operation, .merge)
        store.stopWatching()
    }
    @MainActor
    func testUnseenDotClearsWhileSelectedAndSetsWhenAway() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["r1", "r2"] {
            let r = try await TestHelpers.makeTempRepo()
            try FileManager.default.moveItem(at: r, to: ws.appendingPathComponent(name))
        }
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("c.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store.openUntitled(linkingFolder: ws)
        store.stopWatching()
        let r1 = store.repositories.first { $0.repo.name == "r1" }!
        let r2 = store.repositories.first { $0.repo.name == "r2" }!

        store.select(r1)
        try TestHelpers.write("a\n", to: r1.url, "a.txt")
        await r1.refreshStatus()
        XCTAssertFalse(r1.hasUnseenChanges, "being viewed")
        XCTAssertEqual(ConfigStore(fileURL: cfgURL).loadWithWarning().0.repos[r1.url.path]?.lastViewedFingerprint, r1.fingerprint)

        store.select(r2)
        try TestHelpers.write("b\n", to: r1.url, "b.txt")
        await r1.refreshStatus()
        XCTAssertTrue(r1.hasUnseenChanges)
        XCTAssertFalse(r2.hasUnseenChanges)
        store.select(r1)
        XCTAssertFalse(r1.hasUnseenChanges)
    }

    // MARK: - A5: unseen-changes baseline persists for a never-selected repo

    @MainActor
    func testUnseenBaselinePersistsAtLaunchForUnselectedRepo() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["r1", "r2"] {
            let r = try await TestHelpers.makeTempRepo()
            try FileManager.default.moveItem(at: r, to: ws.appendingPathComponent(name))
        }
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("c.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store.openUntitled(linkingFolder: ws)
        store.stopWatching()
        let r1 = store.repositories.first { $0.repo.name == "r1" }!
        let r2 = store.repositories.first { $0.repo.name == "r2" }!
        store.select(r1) // r2 stays unselected for the whole test.

        // `refreshAll` already persisted r2's baseline in one batched write, even though it was
        // never clicked — not just held in memory until the user first selects it.
        let onDisk = ConfigStore(fileURL: cfgURL).loadWithWarning().0
        XCTAssertEqual(onDisk.repos[r2.url.path]?.lastViewedFingerprint, r2.fingerprint)
        XCTAssertFalse(r2.hasUnseenChanges)

        // A change after that baseline still shows the dot.
        try TestHelpers.write("x\n", to: r2.url, "x.txt")
        await r2.refreshStatus()
        XCTAssertTrue(r2.hasUnseenChanges)
        // The selected repo is never included in the baseline batch — it must never show a dot.
        XCTAssertFalse(r1.hasUnseenChanges)
    }

    @MainActor
    func testFreshWorkspaceStoreOverPersistedBaselineShowsNoDotForUnchangedRepo() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["r1", "r2"] {
            let r = try await TestHelpers.makeTempRepo()
            try FileManager.default.moveItem(at: r, to: ws.appendingPathComponent(name))
        }
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("c.json")
        let store1 = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store1.openUntitled(linkingFolder: ws)
        store1.stopWatching()
        store1.select(store1.repositories.first { $0.repo.name == "r1" }!)
        let fileURL = try XCTUnwrap(store1.fileURL)

        // A second store over the same workspace file and prefs, standing in for a relaunch: r2
        // was never touched again, so its fingerprint still matches the persisted baseline.
        let store2 = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        try await store2.open(fileURL: fileURL)
        store2.stopWatching()
        let r2Again = try XCTUnwrap(store2.repositories.first { $0.repo.name == "r2" })
        XCTAssertFalse(r2Again.hasUnseenChanges)
    }

    @MainActor
    func testFetchCadencePersistsAndFilterSkipsPausedRepo() async throws {
        let ws = try TestHelpers.makeTempDir()
        for name in ["a", "b"] {
            try FileManager.default.moveItem(at: try await TestHelpers.makeTempRepo(), to: ws.appendingPathComponent(name))
        }
        let cfgURL = try TestHelpers.makeTempDir().appendingPathComponent("cfg.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: cfgURL))
        await store.openUntitled(linkingFolder: ws)
        let b = store.repositories.first { $0.repo.name == "b" }!
        store.setFetchCadence(.paused, for: b)
        XCTAssertEqual(b.fetchCadence, .paused)
        XCTAssertEqual(ConfigStore(fileURL: cfgURL).loadWithWarning().0.repos[b.url.path]?.fetchCadence, .paused)

        let due = await store.fetchAll(silent: true) { WorkspaceStore.isFetchDue(cadence: $0.fetchCadence, tick: 5) }
        XCTAssertEqual(due.total, 1, "paused repo is skipped, normal one fetched on tick 5")
        let offTick = await store.fetchAll(silent: true) { WorkspaceStore.isFetchDue(cadence: $0.fetchCadence, tick: 1) }
        XCTAssertEqual(offTick.total, 0, "normal repo waits for every 5th tick")
        let all = await store.fetchAll(silent: true)
        XCTAssertEqual(all.total, 2, "manual fetch ignores cadence")
        store.stopWatching()
    }
}
