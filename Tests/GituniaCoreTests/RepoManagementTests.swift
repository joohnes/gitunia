import XCTest
@testable import GituniaCore

final class RepoManagementParserTests: XCTestCase {
    // Real `git clone --progress file://…` stderr (git 2.50), as raw bytes incl. \r rewrites.
    private let realChunk = "Cloning into 'dst'...\nremote: Enumerating objects: 604, done.        \nremote: Counting objects:  50% (302/604)        \rremote: Counting objects: 100% (604/604), done.        \nremote: Total 604 (delta 300), reused 0 (delta 0), pack-reused 0 (from 0)        \nReceiving objects:  99% (599/604)\rReceiving objects: 100% (604/604), 621.15 KiB | 29.58 MiB/s, done.\nResolving deltas:  45% (135/300)\r"

    func testParserFollowsRealOutputAcrossChunkSplits() {
        var p = CloneProgressParser()
        let cut = realChunk.index(realChunk.startIndex, offsetBy: 200)
        XCTAssertEqual(p.feed(String(realChunk[..<cut])), CloneProgress(phase: "Counting objects", percent: 100))
        XCTAssertEqual(p.feed(String(realChunk[cut...])), CloneProgress(phase: "Resolving deltas", percent: 45))
        XCTAssertNil(p.feed("Resolving del"), "incomplete line waits for its terminator")
        XCTAssertEqual(p.feed("tas: 100% (300/300), done.\n"), CloneProgress(phase: "Resolving deltas", percent: 100))
    }

    func testNameValidation() throws {
        let ws = try TestHelpers.makeTempDir()
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("taken"), withIntermediateDirectories: true)
        XCTAssertNil(NewRepoName.validate("fresh", in: ws))
        XCTAssertNotNil(NewRepoName.validate("", in: ws))
        XCTAssertNotNil(NewRepoName.validate("a/b", in: ws))
        XCTAssertNotNil(NewRepoName.validate("..", in: ws))
        XCTAssertNotNil(NewRepoName.validate(".hidden", in: ws))
        XCTAssertNotNil(NewRepoName.validate("-x", in: ws))
        XCTAssertNotNil(NewRepoName.validate("node_modules", in: ws))
        XCTAssertEqual(NewRepoName.validate("taken", in: ws), "“taken” already exists in that folder.")
    }

    func testSubmoduleParserRealLines() {
        let out = """
         8ee2115261aac34bd7eed205ea40a9fecfe7ec7f libs/lib (heads/master)
        +016ff10069b74d81c99166f6eed45ef0426d4c35 other (heads/master)
        -8ee2115261aac34bd7eed205ea40a9fecfe7ec7f fresh
        U0000000000000000000000000000000000000000 conflicted

        """
        let subs = SubmoduleParser.parse(out)
        XCTAssertEqual(subs.map(\.path), ["libs/lib", "other", "fresh", "conflicted"])
        XCTAssertEqual(subs.map(\.state), [.current, .outOfDate, .uninitialized, .conflict])
        XCTAssertEqual(subs[0].describe, "heads/master")
        XCTAssertNil(subs[2].describe)
        XCTAssertEqual(subs[1].commit, "016ff10069b74d81c99166f6eed45ef0426d4c35")
    }

    func testWorktreeParserRealPorcelain() {
        let out = """
        worktree /p/wtrepo
        HEAD 3d6097d57344930e0e02c34a0c87d59580dd9df9
        branch refs/heads/master

        worktree /p/wt-detached
        HEAD 3d6097d57344930e0e02c34a0c87d59580dd9df9
        detached

        worktree /p/wt-gone
        HEAD 3d6097d57344930e0e02c34a0c87d59580dd9df9
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        worktree /p/wt-locked
        HEAD 3d6097d57344930e0e02c34a0c87d59580dd9df9
        branch refs/heads/locked-br
        locked agent busy


        """
        let wts = WorktreeParser.parse(out)
        XCTAssertEqual(wts.map(\.path), ["/p/wtrepo", "/p/wt-detached", "/p/wt-gone", "/p/wt-locked"])
        XCTAssertEqual(wts.map(\.branch), ["master", nil, "gone", "locked-br"])
        XCTAssertEqual(wts.map(\.isDetached), [false, true, false, false])
        XCTAssertEqual(wts[2].prunableReason, "gitdir file points to non-existent location")
        XCTAssertEqual(wts[3].lockedReason, "agent busy")
        XCTAssertNil(wts[0].lockedReason)
        XCTAssertFalse(wts[0].isPrunable)
    }
}

@MainActor
final class RepoManagementIntegrationTests: XCTestCase {
    private let git = GitRunner()

    private func makeRepo(at url: URL, files: Int = 1) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await git.run(["init", "-q", "-b", "master"], in: url)
        for i in 0..<files { try "file \(i)\n".write(to: url.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
        try await commitAll(url, "init")
    }

    private func commitAll(_ url: URL, _ message: String) async throws {
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["-c", "user.email=t@e", "-c", "user.name=T", "-c", "commit.gpgsign=false", "commit", "-q", "-m", message], in: url)
    }

    private func makeWorkspace() async throws -> (WorkspaceStore, URL) {
        let ws = try TestHelpers.makeTempDir()
        let config = try TestHelpers.makeTempDir().appendingPathComponent("config.json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: config))
        await store.openUntitled(linkingFolder: ws)
        return (store, ws)
    }

    func testCloneReportsProgressAppearsAndIsSelected() async throws {
        let source = try TestHelpers.makeTempDir().appendingPathComponent("src")
        try await makeRepo(at: source, files: 200)
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        var phases: [String] = []
        let dest = try await workspace.cloneRepository(from: "file://\(source.path)", named: "src", in: ws) { phases.append($0.phase) }
        XCTAssertEqual(dest.path, ws.appendingPathComponent("src").path)
        XCTAssertEqual(workspace.selectedRepository?.id, workspace.repository(atPath: dest.path)?.id)
        XCTAssertTrue(phases.contains("Receiving objects"), "\(phases)")
        XCTAssertNotNil(workspace.selectedRepository)
        XCTAssertEqual(workspace.selectedRepository?.repo.branch, "master")
    }

    func testCloneFailureShowsGitMessageAndLeavesNothing() async throws {
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        do {
            let missing = try TestHelpers.makeTempDir().appendingPathComponent("missing")
            try await workspace.cloneRepository(from: "file://\(missing.path)", named: "nope", in: ws)
            XCTFail("expected failure")
        } catch let e as GitError {
            XCTAssertTrue(e.stderr.contains("does not appear to be a git repository"), e.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("nope").path))
    }

    func testCloneErrorNeverShowsPassword() async throws {
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        do {
            // Port 1 on loopback: connection refused immediately, no network involved.
            try await workspace.cloneRepository(from: "https://bot:s3cret@127.0.0.1:1/x.git", named: "x", in: ws)
            XCTFail("expected failure")
        } catch let e as GitError {
            XCTAssertFalse(e.localizedDescription.contains("s3cret"), e.localizedDescription)
            XCTAssertTrue(e.localizedDescription.contains("bot:•••@"), e.localizedDescription)
        }
    }

    func testCloneRejectsExistingDestination() async throws {
        let source = try await TestHelpers.makeTempRepo()
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("mine"), withIntermediateDirectories: true)
        try "keep".write(to: ws.appendingPathComponent("mine/keep.txt"), atomically: true, encoding: .utf8)
        do {
            try await workspace.cloneRepository(from: source.path, named: "mine", in: ws)
            XCTFail("expected rejection")
        } catch is WorkspaceStore.RepoCreationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.appendingPathComponent("mine/keep.txt").path))
    }

    func testCancelKillsCloneAndRemovesPartialFolder() async throws {
        let source = try TestHelpers.makeTempDir().appendingPathComponent("big")
        try await makeRepo(at: source, files: 300)
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let task = Task { @MainActor in
            try await workspace.cloneRepository(from: "file://\(source.path)", named: "big", in: ws) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("big").path))
        XCTAssertNil(workspace.repository(atPath: ws.appendingPathComponent("big").path))
    }

    func testInitCreatesEmptyMainRepoAndSelectsIt() async throws {
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let url = try await workspace.initRepository(named: "fresh", in: ws)
        XCTAssertEqual(url.path, ws.appendingPathComponent("fresh").path)
        let head = try String(contentsOf: url.appendingPathComponent(".git/HEAD"), encoding: .utf8)
        XCTAssertEqual(head, "ref: refs/heads/master\n")
        let count = try await git.run(["rev-list", "--all", "--count"], in: url)
        XCTAssertEqual(count.trimmingCharacters(in: .whitespacesAndNewlines), "0", "init must not commit")
        XCTAssertNotNil(workspace.selectedRepository)
        XCTAssertEqual(workspace.selectedRepository?.id, workspace.repository(atPath: url.path)?.id)
    }

    func testSubmodulesStatusAndUpdate() async throws {
        let base = try TestHelpers.makeTempDir()
        let lib = base.appendingPathComponent("lib"), upstream = base.appendingPathComponent("super")
        try await makeRepo(at: lib)
        try await makeRepo(at: upstream)
        _ = try await git.run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.path, "libs/lib"], in: upstream)
        try await commitAll(upstream, "add submodule")

        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        try await workspace.cloneRepository(from: upstream.path, named: "super", in: ws)
        let store = try XCTUnwrap(workspace.selectedRepository)
        XCTAssertEqual(store.submodules.map(\.state), [.uninitialized])
        XCTAssertTrue(store.hasOutdatedSubmodules)

        let refused = await store.updateSubmodules()
        XCTAssertTrue(refused?.stderr.contains("transport 'file' not allowed") == true, refused?.stderr ?? "no error")

        let error = await store.updateSubmodules(configOverrides: ["protocol.file.allow=always"])
        XCTAssertNil(error)
        XCTAssertEqual(store.submodules.map(\.path), ["libs/lib"])
        XCTAssertEqual(store.submodules.map(\.state), [.current])
        XCTAssertFalse(store.hasOutdatedSubmodules)
        XCTAssertNil(workspace.repository(atPath: ws.appendingPathComponent("super/libs/lib").path),
                     "submodules live inside their superproject, so the scanner never lists them")
    }

    func testWorktreesAreScannedListedAndSelectable() async throws {
        let (workspace, ws) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let master = ws.appendingPathComponent("app")
        try await makeRepo(at: master)
        _ = try await git.run(["worktree", "add", "-q", "../app-feature", "-b", "feature"], in: master)
        _ = try await git.run(["worktree", "add", "-q", "--detach", ".claude/worktrees/agent-1"], in: master)
        _ = try await git.run(["worktree", "add", "-q", "../gone", "-b", "gone"], in: master)
        try FileManager.default.removeItem(at: ws.appendingPathComponent("gone"))

        let realWS = ws.resolvingSymlinksInPath().path + "/"
        XCTAssertEqual(WorkspaceScanner.findRepositories(in: ws).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: realWS, with: "") },
                       ["app", "app-feature", "app/.claude/worktrees/agent-1"])

        await workspace.refreshAll()
        let store = try XCTUnwrap(workspace.repository(atPath: master.path))
        let wts = try await store.worktrees()
        XCTAssertEqual(wts.count, 4)
        let agent = try XCTUnwrap(wts.first { $0.path.hasSuffix("/agent-1") })
        XCTAssertTrue(agent.isDetached)
        XCTAssertTrue(wts.first { $0.path.hasSuffix("/gone") }?.isPrunable == true)
        XCTAssertTrue(agent.path.hasPrefix("/private/"), "git reports realpaths: \(agent.path)")
        let found = try XCTUnwrap(workspace.repository(atPath: agent.path), "realpath must match the scanned /var path")
        workspace.searchQuery = "zzz"
        workspace.select(found)
        XCTAssertEqual(workspace.selectedRepository?.id, found.id)
        XCTAssertEqual(workspace.searchQuery, "")
    }
}
