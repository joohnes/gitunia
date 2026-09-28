import XCTest
@testable import GituniaCore

final class RemotesPureTests: XCTestCase {
    func testRedactsPasswordKeepsUser() {
        XCTAssertEqual(URLRedaction.redact("https://jan:ghp_s3cret@github.com/a/b.git"), "https://jan:•••@github.com/a/b.git")
    }

    func testRedactsTokenAsHTTPUsername() {
        XCTAssertEqual(URLRedaction.redact("https://ghp_s3cret@github.com/a/b.git"), "https://•••@github.com/a/b.git")
    }

    func testPasswordContainingAtIsFullyRedacted() {
        XCTAssertEqual(URLRedaction.redact("https://u:p@ss@host/x"), "https://u:•••@host/x")
    }

    func testLeavesSafeURLsAlone() {
        for url in ["ssh://git@github.com/a/b.git", "git@github.com:a/b.git", "https://github.com/a/b.git", "/tmp/r.git", "../up.git"] {
            XCTAssertEqual(URLRedaction.redact(url), url)
        }
        XCTAssertEqual(URLRedaction.redact("ssh://git:pw@host/x"), "ssh://git:•••@host/x")
    }

    func testRedactsInsideFreeText() {
        let text = "fatal: could not read from 'https://u:tok1@a.com/x' and 'https://tok2@b.com/y'"
        let out = URLRedaction.redact(text)
        XCTAssertFalse(out.contains("tok1")); XCTAssertFalse(out.contains("tok2"))
        XCTAssertEqual(out, "fatal: could not read from 'https://u:•••@a.com/x' and 'https://•••@b.com/y'")
    }

    func testGitErrorRedactsArgsAndStderr() {
        let e = GitError(args: ["remote", "add", "--", "x", "https://u:s3cret@h/x"], exitCode: 3, stderr: "error at https://u:s3cret@h/x")
        XCTAssertFalse(e.errorDescription!.contains("s3cret"))
        XCTAssertFalse(e.stderr.contains("s3cret"))
    }

    func testParsesRemoteListWithSeparatePushURL() {
        let text = "origin\thttps://a/x.git (fetch)\norigin\tssh://b/x.git (push)\nup\t../up.git (fetch)\nup\t../up.git (push)\n"
        XCTAssertEqual(RemoteListParser.parse(text), [
            RemoteInfo(name: "origin", fetchURL: "https://a/x.git", pushURL: "ssh://b/x.git"),
            RemoteInfo(name: "up", fetchURL: "../up.git", pushURL: "../up.git"),
        ])
    }

    func testValidationAndSelection() {
        XCTAssertNotNil(RemoteValidation.nameProblem("", existing: []))
        XCTAssertNotNil(RemoteValidation.nameProblem("-x", existing: []))
        XCTAssertNotNil(RemoteValidation.nameProblem("origin", existing: ["origin"]))
        XCTAssertNil(RemoteValidation.nameProblem("fork", existing: ["origin"]))
        XCTAssertNotNil(RemoteValidation.urlProblem(""))
        XCTAssertNotNil(RemoteValidation.urlProblem("--upload-pack=x"))
        XCTAssertEqual(RemoteSelection.pushRemote(from: ["a", "origin"], preferred: nil), "origin")
        XCTAssertEqual(RemoteSelection.pushRemote(from: ["a", "origin"], preferred: "a"), "a")
        XCTAssertEqual(RemoteSelection.pushRemote(from: ["a", "origin"], preferred: "gone"), "origin")
        XCTAssertEqual(RemoteSelection.pushRemote(from: ["a", "b"], preferred: nil), "a")
        XCTAssertNil(RemoteSelection.pushRemote(from: [], preferred: "a"))
        XCTAssertEqual(RemoteSelection.remote(ofTrackingBranch: "team/fork/feat/x", remotes: ["team", "team/fork"]), "team/fork")
        XCTAssertEqual(RemoteSelection.remote(ofTrackingBranch: "origin/master", remotes: []), "origin")
    }

    func testOldWorkspaceJSONStillDecodes() throws {
        let json = #"{"repos":{"/r":{"tags":["x"],"localAIOnly":true}},"workspacePath":"/w"}"#
        let cfg = try JSONDecoder().decode(WorkspaceConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.repos["/r"]?.tags, ["x"])
        XCTAssertNil(cfg.repos["/r"]?.defaultRemote)
    }

    func testDefaultRemoteRoundTrips() throws {
        let store = ConfigStore(fileURL: try TestHelpers.makeTempDir().appendingPathComponent("workspace.json"))
        var cfg = WorkspaceConfig()
        var prefs = RepoPrefs(tags: ["a"])
        prefs.defaultRemote = "backup"
        cfg.repos["/r"] = prefs
        try store.save(cfg)
        XCTAssertEqual(store.loadWithWarning().0.repos["/r"]?.defaultRemote, "backup")
    }
}

/// Real git in throwaway temp repos: `origin` and `backup` are both bare repos in a temp dir.
@MainActor
final class RemotesStoreTests: XCTestCase {
    private let git = GitRunner()

    private func makeRepoWithTwoRemotes() async throws -> (repo: URL, origin: URL, backup: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let dir = try TestHelpers.makeTempDir()
        let origin = dir.appendingPathComponent("origin.git"), backup = dir.appendingPathComponent("backup.git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", origin.path], in: repo)
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", backup.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", origin.path], in: repo)
        _ = try await git.run(["remote", "add", "backup", backup.path], in: repo)
        return (repo, origin, backup)
    }

    private func head(of bare: URL, _ ref: String = "refs/heads/master") async -> String? {
        let out = (try? await git.run(["rev-parse", "--verify", "-q", ref], in: bare, allowedExitCodes: [0, 1])) ?? ""
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }


    func testAddValidatesAndLists() async throws {
        let (url, _, _) = try await makeRepoWithTwoRemotes()
        let store = RepositoryStore(url: url)
        let fork = try TestHelpers.makeTempDir().path
        guard case .invalid = await store.addRemote(name: "origin", url: fork) else { return XCTFail("duplicate accepted") }
        guard case .invalid = await store.addRemote(name: "a b", url: fork) else { return XCTFail("space accepted") }
        guard case .invalid = await store.addRemote(name: "a..b", url: fork) else { return XCTFail("'..' accepted") }
        guard case .invalid = await store.addRemote(name: "fork", url: "  ") else { return XCTFail("empty URL accepted") }
        let result = await store.addRemote(name: " fork ", url: fork)
        XCTAssertEqual(result, .succeeded)
        let remotes = await store.listRemotes()
        XCTAssertEqual(remotes.map(\.name), ["backup", "fork", "origin"])
        XCTAssertEqual(remotes.first { $0.name == "fork" }?.fetchURL, fork)
        XCTAssertEqual(store.remoteNames, ["backup", "fork", "origin"])
    }


    func testRenameMovesUpstreamAndChangeURL() async throws {
        let (url, _, backup) = try await makeRepoWithTwoRemotes()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        _ = await store.push()
        XCTAssertEqual(store.upstreamRemote, "origin")
        guard case .invalid = await store.renameRemote("origin", to: "backup") else { return XCTFail("duplicate accepted") }
        let renamed = await store.renameRemote("origin", to: "upstream")
        XCTAssertEqual(renamed, .succeeded)
        XCTAssertEqual(store.upstreamRemote, "upstream")
        XCTAssertTrue(store.branches.contains { $0.name == "upstream/master" && $0.isRemote })

        let changed = await store.setRemoteURL("upstream", to: backup.path)
        XCTAssertEqual(changed, .succeeded)
        let listed = await store.listRemotes()
        XCTAssertEqual(listed.first { $0.name == "upstream" }?.fetchURL, backup.path)
        guard case .failed(let message) = await store.setRemoteURL("nope", to: "https://u:s3cret@host/x") else { return XCTFail() }
        XCTAssertTrue(message.contains("No such remote"), message)
        XCTAssertFalse(message.contains("s3cret"))
    }


    func testRemoveReportsImpactThenDropsRefsAndUpstream() async throws {
        let (url, _, _) = try await makeRepoWithTwoRemotes()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        _ = await store.push()
        _ = try await git.run(["branch", "--track", "feat", "origin/master"], in: url)
        _ = try await git.run(["remote", "set-head", "origin", "master"], in: url)

        let impact = await store.removalImpact(of: "origin")
        XCTAssertEqual(impact, RemoteRemovalImpact(trackingRefCount: 1, trackingBranches: ["feat", "master"]))
        let backupImpact = await store.removalImpact(of: "backup")
        XCTAssertEqual(backupImpact, RemoteRemovalImpact(trackingRefCount: 0, trackingBranches: []))

        let removed = await store.removeRemote("origin")
        XCTAssertEqual(removed, .succeeded)
        XCTAssertEqual(store.remoteNames, ["backup"])
        XCTAssertFalse(store.hasUpstream)
        XCTAssertFalse(store.branches.contains { $0.isRemote })
        let featRemote = try await git.run(["config", "--get", "branch.feat.remote"], in: url, allowedExitCodes: [0, 1])
        XCTAssertEqual(featRemote, "")
    }


    func testFirstPushUsesDefaultRemote() async throws {
        let (url, origin, backup) = try await makeRepoWithTwoRemotes()
        let store = RepositoryStore(url: url, prefs: { var p = RepoPrefs(); p.defaultRemote = "backup"; return p }())
        await store.refreshStatus()
        let result = await store.push()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.summary, "Pushed to backup/master")
        XCTAssertEqual(store.upstreamRemote, "backup")
        let b = await head(of: backup), o = await head(of: origin)
        XCTAssertNotNil(b)
        XCTAssertNil(o)
    }


    func testFetchWithoutUpstreamUsesDefaultRemote() async throws {
        let (url, _, backup) = try await makeRepoWithTwoRemotes()
        // Put a branch on backup from elsewhere, so only a fetch from backup can see it.
        let other = try await TestHelpers.makeTempRepo()
        _ = try await git.run(["push", "-q", backup.path, "master:shared"], in: other)

        let plain = RepositoryStore(url: url)
        await plain.refreshStatus()
        _ = await plain.fetch()                       // no default: plain `git fetch` → origin only
        XCTAssertFalse(plain.branches.contains { $0.name == "backup/shared" })

        let store = RepositoryStore(url: url, prefs: { var p = RepoPrefs(); p.defaultRemote = "backup"; return p }())
        await store.refreshStatus()
        let fetched = await store.fetch()
        XCTAssertTrue(fetched.succeeded)
        XCTAssertTrue(store.branches.contains { $0.name == "backup/shared" })
    }


    func testFetchFromSpecificRemote() async throws {
        let (url, _, backup) = try await makeRepoWithTwoRemotes()
        let other = try await TestHelpers.makeTempRepo()
        _ = try await git.run(["push", "-q", backup.path, "master:shared"], in: other)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let result = await store.fetch(from: "backup")
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(store.branches.contains { $0.name == "backup/shared" })
    }


    func testSetAndUnsetUpstreamRefreshAheadBehind() async throws {
        let (url, _, backup) = try await makeRepoWithTwoRemotes()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        _ = await store.push()                        // master → origin/master, upstream set
        _ = try await git.run(["push", "-q", "backup", "master"], in: url)
        try TestHelpers.write("x\n", to: url, "x.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "x"))
        XCTAssertEqual(store.repo.ahead, 1)

        let unset = await store.unsetUpstream()
        XCTAssertTrue(unset)
        XCTAssertFalse(store.hasUpstream)
        XCTAssertEqual(store.repo.ahead, 0)

        let set = await store.setUpstream(to: "backup/master")
        XCTAssertTrue(set)
        XCTAssertTrue(store.hasUpstream)
        XCTAssertEqual(store.upstreamRemote, "backup")
        XCTAssertEqual(store.repo.ahead, 1)

        let bad = await store.setUpstream(to: "backup/nope")
        XCTAssertFalse(bad)
        XCTAssertTrue(store.lastError?.stderr.contains("does not exist") ?? false)
        _ = backup
    }

    /// Force push must push exactly its own branch to its own upstream's remote — never the
    /// default remote, even when one is set and differs.

    func testForcePushIgnoresDefaultRemote() async throws {
        let (url, origin, backup) = try await makeRepoWithTwoRemotes()
        let store = RepositoryStore(url: url, prefs: { var p = RepoPrefs(); p.defaultRemote = "backup"; return p }())
        await store.refreshStatus()
        _ = try await git.run(["push", "-q", "-u", "origin", "master"], in: url)
        _ = try await git.run(["push", "-q", "backup", "master"], in: url)
        await store.refreshStatus()
        let backupBefore = await head(of: backup)
        _ = try await git.run(["commit", "-q", "--amend", "-m", "rewritten"], in: url)
        await store.refreshStatus()

        let result = await store.forcePush()
        XCTAssertTrue(result.succeeded, result.error?.stderr ?? "")
        let local = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        let originAfter = await head(of: origin), backupAfter = await head(of: backup)
        XCTAssertEqual(originAfter, local)
        XCTAssertEqual(backupAfter, backupBefore)
        XCTAssertNotEqual(backupBefore, local)
    }


    /// A6: `hasGitHubRemote` is cached per store — changing `origin` (e.g. in the Remotes sheet)
    /// must invalidate it, not leave the PR toolbar reading the old remote forever.
    func testGitHubRemoteCacheResetsWhenOriginAdded() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let before = await store.checkGitHubRemote()
        XCTAssertFalse(before)
        let added = await store.addRemote(name: "origin", url: "https://github.com/o/r.git")
        XCTAssertEqual(added, .succeeded)
        let after = await store.checkGitHubRemote()
        XCTAssertTrue(after)
    }

    func testWorkspaceSetDefaultRemotePersistsAndApplies() async throws {
        let (url, _, _) = try await makeRepoWithTwoRemotes()
        let configURL = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configURL))
        let store = RepositoryStore(url: url)
        workspace.setDefaultRemote("backup", for: store)
        XCTAssertEqual(store.defaultRemote, "backup")
        XCTAssertEqual(ConfigStore(fileURL: configURL).loadWithWarning().0.repos[url.path]?.defaultRemote, "backup")
        workspace.setDefaultRemote(nil, for: store)
        XCTAssertNil(store.defaultRemote)
    }
}
