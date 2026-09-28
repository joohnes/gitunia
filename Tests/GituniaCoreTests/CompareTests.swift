import XCTest
@testable import GituniaCore

// MARK: - CompareBase.resolve (pure)

final class CompareBaseTests: XCTestCase {
    func testResolve() {
        // An empty `originHEADRef` is what `git symbolic-ref` prints for an unset ref (exit 128);
        // nil means the process call itself failed. With no local branch of origin/HEAD's name the
        // remote-tracking ref is used, so the base always resolves.
        let cases: [(originHEAD: String?, local: [String], expected: String?)] = [
            ("refs/remotes/origin/develop\n", ["master", "develop"], "develop"),
            ("refs/remotes/origin/develop\n", ["master"], "origin/develop"),
            ("", ["master", "feature"], "master"),
            (nil, ["master", "feature"], "master"),
            (nil, ["main", "feature"], "main"),
            (nil, ["feature"], nil),
            (nil, ["main", "master"], "master"),
        ]
        for c in cases {
            XCTAssertEqual(CompareBase.resolve(originHEADRef: c.originHEAD, localBranches: c.local), c.expected,
                           "\(String(describing: c.originHEAD)) \(c.local)")
        }
    }
}

// MARK: - RepositoryStore compareCounts / compareCommits / compareDiff (real git)

final class CompareOpsIntegrationTests: XCTestCase {
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
}
