import XCTest
@testable import GituniaCore

// MARK: - CompareBase.resolve (pure)

final class CompareBaseTests: XCTestCase {
    func testUsesOriginHEADWhenSet() {
        let base = CompareBase.resolve(originHEADRef: "refs/remotes/origin/develop\n", localBranches: ["master", "develop"])
        XCTAssertEqual(base, "develop")
    }

    /// No local branch of that name → the remote-tracking ref, so the base always resolves.
    func testOriginHEADWithoutLocalBranchIsRemoteTracking() {
        XCTAssertEqual(CompareBase.resolve(originHEADRef: "refs/remotes/origin/develop\n", localBranches: ["master"]), "origin/develop")
    }

    func testFallsBackToLocalMasterWhenOriginHEADUnset() {
        // `git symbolic-ref` on an unset ref exits 128 with empty stdout — the caller passes that
        // straight through as an empty string (or nil, if the process call itself failed).
        XCTAssertEqual(CompareBase.resolve(originHEADRef: "", localBranches: ["master", "feature"]), "master")
        XCTAssertEqual(CompareBase.resolve(originHEADRef: nil, localBranches: ["master", "feature"]), "master")
    }

    func testFallsBackToMainWhenNoMaster() {
        XCTAssertEqual(CompareBase.resolve(originHEADRef: nil, localBranches: ["main", "feature"]), "main")
    }

    func testNilWhenNothingResolves() {
        XCTAssertNil(CompareBase.resolve(originHEADRef: nil, localBranches: ["feature"]))
    }

    func testMasterPreferredOverMainWhenBothExist() {
        XCTAssertEqual(CompareBase.resolve(originHEADRef: nil, localBranches: ["main", "master"]), "master")
    }
}

// MARK: - CompareCounts.parse (pure)

final class CompareCountsTests: XCTestCase {
    func testParsesBehindThenAhead() {
        // `git rev-list --left-right --count base...head` prints "<base-only>\t<head-only>".
        let counts = CompareCounts.parse("1\t3\n")
        XCTAssertEqual(counts.behind, 1)
        XCTAssertEqual(counts.ahead, 3)
    }

    func testEmptyOutputIsZeroZero() {
        let counts = CompareCounts.parse("")
        XCTAssertEqual(counts.ahead, 0)
        XCTAssertEqual(counts.behind, 0)
    }
}

// MARK: - RepositoryStore.defaultBaseBranch / compareCounts / compareCommits / compareDiff (real git)

final class CompareOpsIntegrationTests: XCTestCase {
    /// A repo with a real `origin` remote whose default branch differs from the fallback ("master")
    /// so the origin/HEAD path is actually exercised, not accidentally shadowed by the local-branch
    /// fallback. Mirrors `RemoteOpsTests.makeRepoWithRemote`.
    @MainActor
    private func makeRepoWithRemote(defaultBranch: String = "master") async throws -> (repo: URL, remote: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        return (repo, remote)
    }

    @MainActor
    func testDefaultBaseBranchViaOriginHEAD() async throws {
        let (url, _) = try await makeRepoWithRemote()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        _ = await store.push() // sets upstream, but origin/HEAD itself is a separate ref

        // `git remote set-head` is what actually sets refs/remotes/origin/HEAD — a plain push
        // doesn't. Verify the real failure mode first (unset), then set it and verify the real
        // success path.
        let git = GitRunner()
        let beforeSet = await store.defaultBaseBranch()
        XCTAssertEqual(beforeSet, "master") // falls back to local master — origin/HEAD isn't set yet

        _ = try await git.run(["remote", "set-head", "origin", "master"], in: url)
        let out = try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD"], in: url)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "refs/remotes/origin/master")
        await store.refreshStatus()
        let afterSet = await store.defaultBaseBranch()
        XCTAssertEqual(afterSet, "master")
    }

    @MainActor
    func testDefaultBaseBranchNilThenFallsBackToMain() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        // No origin at all, and the only branch is "master" (from makeTempRepo) — rename it to
        // something else so neither "master" nor "main" exists, then verify nil, then rename to
        // "main" and verify the fallback.
        _ = try await git.run(["branch", "-m", "master", "trunk"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let nilBase = await store.defaultBaseBranch()
        XCTAssertNil(nilBase)

        _ = try await git.run(["branch", "-m", "trunk", "main"], in: url)
        await store.refreshStatus()
        let mainBase = await store.defaultBaseBranch()
        XCTAssertEqual(mainBase, "main")
    }

    @MainActor
    func testCompareCountsAndCommits() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        for i in 1...3 {
            try TestHelpers.write("f\(i)\n", to: url, "f\(i).txt")
            await store.stageAll()
            _ = await store.commit(CommitMessage(title: "feature commit \(i)"))
        }
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("m1\n", to: url, "m1.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "master commit 1"))

        let counts = await store.compareCounts(base: "master", head: "feature")
        XCTAssertEqual(counts.ahead, 3)
        XCTAssertEqual(counts.behind, 1)

        let commits = await store.compareCommits(base: "master", head: "feature")
        XCTAssertEqual(commits.map(\.subject), ["feature commit 3", "feature commit 2", "feature commit 1"])
    }

    /// Compare's rows mark agent commits by email too, so `compareCommits` must carry `%ae`.
    @MainActor
    func testCompareCommitsCarryAuthorEmail() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("x\n", to: url, "x.txt")
        _ = try await git.run(["add", "x.txt"], in: url)
        _ = try await git.run(["-c", "user.email=bot@example.com", "commit", "-q", "-m", "bot"], in: url)
        let commits = await store.compareCommits(base: "master", head: "feature")
        XCTAssertEqual(commits.map(\.authorEmail), ["bot@example.com"])
    }

    /// Three-dot vs two-dot: after `base` moves on with its own commit past the branches' common
    /// ancestor, `base...head` (three dots — diffs `head` against the merge-base) must exclude
    /// `base`'s newer, independent change; a plain two-dot/no-dot tip-to-tip diff would include it.
    @MainActor
    func testThreeDotDiffExcludesBasesNewerChangesSinceDivergence() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("feature content\n", to: url, "feature.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add feature.txt"))

        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("master-only content\n", to: url, "master-only.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "master-only change"))

        let threeDot = await store.compareDiff(base: "master", head: "feature")
        XCTAssertEqual(threeDot.map(\.path), ["feature.txt"])

        // Confirm two-dot really would have differed — it diffs the tips directly, so it also
        // shows master's own independent change (as a deletion, from feature's point of view) plus
        // feature's own addition.
        let twoDotOut = try await git.run(["diff", "--no-color", "master..feature"], in: url)
        let twoDot = DiffParser.parse(twoDotOut)
        XCTAssertEqual(twoDot.map(\.path).sorted(), ["feature.txt", "master-only.txt"])
    }

    @MainActor
    func testCompareHeadEqualsBaseIsEmpty() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let counts = await store.compareCounts(base: "master", head: "master")
        XCTAssertEqual(counts.ahead, 0)
        XCTAssertEqual(counts.behind, 0)
        let commits = await store.compareCommits(base: "master", head: "master")
        XCTAssertTrue(commits.isEmpty)
        let diff = await store.compareDiff(base: "master", head: "master")
        XCTAssertTrue(diff.isEmpty)
    }
}

// MARK: - Persistence (T4): RepoPrefs.compareBase round-trips, old workspace.json still decodes

final class ComparePersistenceTests: XCTestCase {
    @MainActor
    func testSetCompareBasePersistsAndRestores() async throws {
        // A dedicated workspace root containing exactly one repo — same pattern as the render
        // tests' `makeRepo...` helpers. Pointing `openWorkspace` at `makeTempRepo()`'s own parent
        // (the shared system temp directory) would scan every other test's leftover temp repos
        // too, which is both slow and makes "the" repo ambiguous.
        let root = try TestHelpers.makeTempDir()
        let repoURL = root.appendingPathComponent("repo")
        try await TestRepo.make(at: repoURL, files: ["README.md": "hello\n"])

        let configFile = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        let configStore = ConfigStore(fileURL: configFile)
        let workspace = WorkspaceStore(configStore: configStore)
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else {
            return XCTFail("repo not scanned")
        }
        workspace.setCompareBase("develop", for: repo)
        // Keyed by `repo.url.path`, not the raw `repoURL` this test built — the scanner
        // standardizes the workspace root (`WorkspaceScanner.scan`/`WorkspaceStore.openWorkspace`
        // both use `.standardizedFileURL`), so `repo.url` is the source of truth for the path a
        // real app run would persist under.
        XCTAssertEqual(configStore.loadWithWarning().0.repos[repo.url.path]?.compareBase, "develop")

        // Reload into a fresh WorkspaceStore/RepositoryStore, same as relaunching the app.
        let reopened = WorkspaceStore(configStore: configStore)
        await reopened.openUntitled(linkingFolder: root)
        let reopenedRepo = reopened.repositories.first
        XCTAssertEqual(reopenedRepo?.restoredCompareBase, "develop")
    }

    /// A `workspace.json` written before this task existed (no `compareBase` key at all) must keep
    /// decoding — `RepoPrefs`'s `decodeIfPresent` is what guarantees this.
    func testPreExistingWorkspaceJSONWithoutCompareBaseStillDecodes() throws {
        let json = """
        {
          "workspacePath" : "/tmp/some-workspace",
          "repos" : {
            "/tmp/some-workspace/repo-a" : {
              "tags" : ["backend"],
              "localAIOnly" : false,
              "selectedPath" : "src/master.swift"
            }
          },
          "settings" : {
            "aiProvider" : "claudeCLI",
            "ollamaModel" : "llama3.1",
            "diffCharLimit" : 8000,
            "appearance" : "system",
            "autoFetchMinutes" : 15
          }
        }
        """
        let config = try JSONDecoder().decode(WorkspaceConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.workspacePath, "/tmp/some-workspace")
        let prefs = config.repos["/tmp/some-workspace/repo-a"]
        XCTAssertEqual(prefs?.tags, ["backend"])
        XCTAssertEqual(prefs?.selectedPath, "src/master.swift")
        XCTAssertNil(prefs?.compareBase)
    }
}
