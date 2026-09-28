import XCTest
@testable import GituniaCore

/// Compare with a worktree endpoint: its working tree (committed + uncommitted + untracked).
@MainActor
final class WorktreeCompareTests: XCTestCase {
    /// master (README "hello") + worktree `wt` on `feat`: one commit adding a.txt, an uncommitted
    /// README edit, and an untracked new.txt.
    private func makeRepoWithWorktree() async throws -> (repo: URL, wt: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let wt = try TestHelpers.makeTempDir().appendingPathComponent("wt")
        let git = GitRunner()
        _ = try await git.run(["worktree", "add", "-q", "-b", "feat", wt.path], in: repo)
        try TestHelpers.write("a\n", to: wt, "a.txt")
        _ = try await git.run(["add", "a.txt"], in: wt)
        _ = try await git.run(["commit", "-q", "-m", "add a"], in: wt)
        try TestHelpers.write("hello\nwt\n", to: wt, "README.md")
        try TestHelpers.write("new\n", to: wt, "new.txt")
        return (repo, wt)
    }

    func testWorktreeVsRefIncludesCommittedUncommittedAndUntracked() async throws {
        let (repo, wt) = try await makeRepoWithWorktree()
        let store = RepositoryStore(url: repo)
        let head = CompareEndpoint.worktree(path: wt, label: "wt · feat")
        let files = await store.compareDiff(base: .ref("master"), head: head)
        XCTAssertEqual(Set(files.map(\.path)), ["README.md", "a.txt", "new.txt"])
        XCTAssertEqual(RepositoryStore.uncommittedLabels(base: .ref("master"), head: head), ["wt · feat"])

        let counts = await store.compareCounts(base: .ref("master"), head: head)
        XCTAssertEqual(counts.ahead, 1)
        XCTAssertEqual(counts.behind, 0)
        let commits = await store.compareCommits(base: .ref("master"), head: head)
        XCTAssertEqual(commits.map(\.subject), ["add a"])
    }

    func testWorktreeVsWorktreeDiffsBothWorkingTrees() async throws {
        let (repo, wt) = try await makeRepoWithWorktree()
        let wt2 = try TestHelpers.makeTempDir().appendingPathComponent("wt2")
        _ = try await GitRunner().run(["worktree", "add", "-q", "-b", "feat2", wt2.path, "master"], in: repo)
        try TestHelpers.write("hello\nwt2\n", to: wt2, "README.md")

        let store = RepositoryStore(url: repo)
        let (base, head) = (CompareEndpoint.worktree(path: wt, label: "wt"), CompareEndpoint.worktree(path: wt2, label: "wt2"))
        let files = await store.compareDiff(base: base, head: head)
        let readme = files.filter { $0.path == "README.md" }
        XCTAssertEqual(readme.count, 1)
        let lines = readme.first?.hunks.flatMap(\.lines) ?? []
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text == "wt" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "wt2" })
        // a.txt (committed) and new.txt (untracked) exist only in the base worktree.
        XCTAssertEqual(Set(files.map(\.path)), ["README.md", "a.txt", "new.txt"])
        XCTAssertEqual(RepositoryStore.uncommittedLabels(base: base, head: head), ["wt", "wt2"])

        // feat2 has no commits; feat is 1 ahead of it.
        let counts = await store.compareCounts(base: base, head: head)
        XCTAssertEqual(counts.ahead, 0)
        XCTAssertEqual(counts.behind, 1)
        let commits = await store.compareCommits(base: head, head: base)
        XCTAssertEqual(commits.map(\.subject), ["add a"])
    }

    /// B9: `FileDiffPane.contentRoot` uses this to point "Open in Editor" at the compared worktree.
    func testContentRoot() {
        XCTAssertEqual(CompareEndpoint.worktree(path: URL(fileURLWithPath: "/tmp/x/wt"), label: "wt").contentRoot,
                        URL(fileURLWithPath: "/tmp/x/wt"))
        XCTAssertNil(CompareEndpoint.ref("master").contentRoot)
    }

    /// B9: resolves a worktree's real gitdir (`<master>/.git/worktrees/<name>`) from its `.git` file,
    /// so the Compare fallback watcher can watch commits made there too.
    func testGitDirForWorktree() async throws {
        let (repo, wt) = try await makeRepoWithWorktree()
        let resolved = RepositoryStore.gitDir(forWorktree: wt)
        XCTAssertEqual(resolved?.standardizedFileURL.path,
                        repo.appendingPathComponent(".git/worktrees/wt").standardizedFileURL.path)
    }

    func testSelectionRoundTrip() {
        let wt = Worktree(path: "/tmp/x/wt", head: "abc1234def", branch: "feat", isDetached: false, isBare: false,
                          lockedReason: nil, prunableReason: nil)
        let endpoint = CompareEndpoint(selection: CompareEndpoint.selection(for: wt), worktrees: [wt])
        XCTAssertEqual(endpoint, .worktree(path: URL(fileURLWithPath: "/tmp/x/wt"), label: "wt · feat"))
        XCTAssertEqual(CompareEndpoint(selection: "master", worktrees: [wt]), .ref("master"))
    }
}
