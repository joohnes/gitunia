import XCTest
@testable import GituniaCore

/// Tags, branch-from-commit and merged-branch cleanup — parser fixtures are real
/// `git for-each-ref` output; store tests run against throwaway temp repos.
final class TagOpsTests: XCTestCase {
    // MARK: - Pure

    /// Captured from git 2.x: `nested/v3` annotated with empty message, `v1` lightweight (its
    /// `%(contents)` is the commit message and must be ignored), `v2` annotated, two-line message.
    func testParseRealForEachRefOutput() {
        let text = "refs/tags/nested/v3\u{1f}b6dc1943a301c9ff1ca4cebd31a5903aa37a1701\u{1f}2fa71d2a53ee614d23f8e4cd59e9b01fadd23235\u{1f}tag\u{1f}\u{1e}\n"
            + "refs/tags/v1\u{1f}2fa71d2a53ee614d23f8e4cd59e9b01fadd23235\u{1f}\u{1f}commit\u{1f}init commit\n\u{1e}\n"
            + "refs/tags/v2\u{1f}d07a1fef3a50895d64a2463162076986f94884d8\u{1f}2fa71d2a53ee614d23f8e4cd59e9b01fadd23235\u{1f}tag\u{1f}Release two\nsecond line\n\u{1e}\n"
        let head = "2fa71d2a53ee614d23f8e4cd59e9b01fadd23235"
        XCTAssertEqual(TagParser.parse(text), [
            GitTag(name: "nested/v3", commitHash: head, isAnnotated: true, message: nil),
            GitTag(name: "v1", commitHash: head, isAnnotated: false, message: nil),
            GitTag(name: "v2", commitHash: head, isAnnotated: true, message: "Release two\nsecond line"),
        ])
        XCTAssertEqual(TagParser.byCommit(TagParser.parse(text)), [head: ["nested/v3", "v1", "v2"]])
        XCTAssertEqual(TagParser.parse(""), [])
    }

    /// Base resolution itself is `CompareBase.resolve` (CompareTests); this is only the filter.
    func testMergedCleanupCandidates() {
        XCTAssertEqual(MergedCleanup.candidates(merged: ["a", "master", "cur", "feat/x"], base: "origin/master", current: "cur"), ["a", "feat/x"])
        XCTAssertEqual(MergedCleanup.candidates(merged: ["a", "master"], base: "master", current: nil), ["a"])
        // A local base with a slash is excluded as itself — not its last path component.
        XCTAssertEqual(MergedCleanup.candidates(merged: ["x", "feature/x"], base: "feature/x", current: nil), ["x"])
    }

    // MARK: - Tags against real repos

    @MainActor
    func testCreateLightweightAndAnnotatedThenDelete() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let head = try await GitRunner().run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)

        let light = await store.createTag("v1", at: head)
        let annotated = await store.createTag("v2", at: head, message: "Release\n\nnotes")
        XCTAssertEqual(light, .succeeded)
        XCTAssertEqual(annotated, .succeeded)
        XCTAssertEqual(store.gitTags, [
            GitTag(name: "v1", commitHash: head, isAnnotated: false, message: nil),
            GitTag(name: "v2", commitHash: head, isAnnotated: true, message: "Release\n\nnotes"),
        ])

        let deleted = await store.deleteTag("v1")
        XCTAssertTrue(deleted)
        XCTAssertEqual(store.gitTags.map(\.name), ["v2"])
    }

    @MainActor
    func testDuplicateAndInvalidTagNamesRejected() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let dup1 = await store.createTag("v1", at: "HEAD")
        let dup2 = await store.createTag("v1", at: "HEAD")
        let bad1 = await store.createTag("bad..name", at: "HEAD")
        let bad2 = await store.createTag("has space", at: "HEAD")
        let bad3 = await store.createTag("  ", at: "HEAD")
        XCTAssertEqual(dup1, .succeeded)
        XCTAssertEqual(dup2, .duplicateName)
        XCTAssertEqual(bad1, .invalidName("\"bad..name\" isn't a valid tag name"))
        XCTAssertEqual(bad2, .invalidName("\"has space\" isn't a valid tag name"))
        XCTAssertEqual(bad3, .invalidName("Tag name can't be empty"))
    }

    @MainActor
    func testPushTagDeleteOnRemoteAndPushAll() async throws {
        let (url, remote) = try await Self.makeRepoWithRemote()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        _ = await store.createTag("v1", at: "HEAD")
        _ = await store.createTag("v2", at: "HEAD", message: "two")

        let pushed = await store.pushTag("v1")
        XCTAssertTrue(pushed)
        var remoteTags = try await git.run(["tag"], in: remote)
        XCTAssertEqual(remoteTags, "v1\n")

        let deletedRemote = await store.deleteRemoteTag("v1")
        XCTAssertTrue(deletedRemote)
        remoteTags = try await git.run(["tag"], in: remote)
        XCTAssertEqual(remoteTags, "")
        XCTAssertEqual(store.gitTags.map(\.name), ["v1", "v2"], "remote delete keeps the local tag")

        let pushedAll = await store.pushAllTags()
        XCTAssertTrue(pushedAll)
        remoteTags = try await git.run(["tag"], in: remote)
        XCTAssertEqual(remoteTags, "v1\nv2\n")
    }

    @MainActor
    func testPushTagWithoutRemoteFailsWithMessage() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        _ = await store.createTag("v1", at: "HEAD")
        let pushed = await store.pushTag("v1")
        XCTAssertFalse(pushed)
        XCTAssertTrue(store.lastError?.stderr.contains("No remote configured") == true)
    }

    @MainActor
    func testCheckoutTagDetachesHead() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        _ = await store.createTag("v1", at: "HEAD", message: "annotated")
        let ok = await store.checkoutTag("v1")
        XCTAssertTrue(ok)
        let symbolic = try await GitRunner().run(["symbolic-ref", "-q", "HEAD"], in: url, allowedExitCodes: [0, 1])
        XCTAssertEqual(symbolic, "", "HEAD is detached")
    }

    // MARK: - Branch from a commit

    @MainActor
    func testCreateBranchAtCommitWithAndWithoutCheckout() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let first = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestHelpers.write("x\n", to: url, "x.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "second"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let plain = await store.createBranch("old", at: first, checkout: false)
        XCTAssertEqual(plain, .succeeded)
        XCTAssertEqual(store.repo.branch, "master")
        let oldTip = try await git.run(["rev-parse", "old"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(oldTip, first)

        let switched = await store.createBranch("old2", at: first, checkout: true)
        XCTAssertEqual(switched, .succeeded)
        XCTAssertEqual(store.repo.branch, "old2")

        let dup = await store.createBranch("old", at: first, checkout: false)
        let bad = await store.createBranch("bad..x", at: first, checkout: false)
        XCTAssertEqual(dup, .duplicateName)
        XCTAssertEqual(bad, .invalidName("\"bad..x\" isn't a valid branch name"))
    }

    // MARK: - Merged cleanup

    @MainActor
    func testMergedCandidatesAgainstMainAndDelete() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["branch", "done1"], in: url)
        _ = try await git.run(["branch", "done2"], in: url)
        _ = try await git.run(["checkout", "-q", "-b", "wip"], in: url)
        try TestHelpers.write("w\n", to: url, "w.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "wip"], in: url)
        _ = try await git.run(["checkout", "-q", "-b", "cur", "master"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let candidates = await store.mergedBranchCandidates()
        XCTAssertEqual(candidates?.base, "master")
        XCTAssertEqual(candidates?.branches, ["done1", "done2"], "excludes current (cur), base (master), unmerged (wip)")

        let result = await store.deleteMergedBranches(["done1", "wip"])
        XCTAssertEqual(result.deleted, ["done1"])
        XCTAssertEqual(result.refused.map(\.name), ["wip"])
        XCTAssertEqual(result.refused.first?.reason, "error: the branch 'wip' is not fully merged")
        XCTAssertEqual(store.branches.filter { !$0.isRemote }.map(\.name).sorted(), ["cur", "done2", "master", "wip"])
    }

    @MainActor
    func testMergedCandidatesUseOriginHead() async throws {
        let (url, _) = try await Self.makeRepoWithRemote()
        let git = GitRunner()
        _ = try await git.run(["push", "-q", "-u", "origin", "master"], in: url)
        _ = try await git.run(["remote", "set-head", "origin", "master"], in: url)
        _ = try await git.run(["branch", "merged"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let candidates = await store.mergedBranchCandidates()
        XCTAssertEqual(candidates?.base, "master", "origin/HEAD → master, as the local branch Compare shows")
        XCTAssertEqual(candidates?.branches, ["merged"])
    }

    /// The base the user picked in Compare (persisted per repo) wins over origin/HEAD/master.
    @MainActor
    func testMergedCandidatesHonourPersistedCompareBase() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "develop"], in: url)
        try TestHelpers.write("d\n", to: url, "d.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "d"], in: url)
        _ = try await git.run(["branch", "onDevelop"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        let store = RepositoryStore(url: url, prefs: RepoPrefs(compareBase: "develop"))
        await store.refreshStatus()
        let candidates = await store.mergedBranchCandidates()
        XCTAssertEqual(candidates?.base, "develop")
        XCTAssertEqual(candidates?.branches, ["onDevelop"], "merged into develop, minus develop itself and current master")
    }

    static func makeRepoWithRemote() async throws -> (repo: URL, remote: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        return (repo, remote)
    }
}
