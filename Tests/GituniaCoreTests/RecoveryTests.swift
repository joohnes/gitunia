import XCTest
@testable import GituniaCore

/// Reflog, reset to a commit, detached HEAD — against real temp repos and real git output.
final class RecoveryTests: XCTestCase {
    // MARK: - Parser (fixture captured verbatim from git 2.50.1)

    func testReflogParserOnCapturedOutput() {
        let raw = "HEAD@{1790180042}\u{1f}ac4ab04aaaa\u{1f}ac4ab04\u{1f}pull -q --ff-only: Fast-forward\u{1e}\n"
            + "HEAD@{1790180031}\u{1f}11287aabbbb\u{1f}11287aa\u{1f}commit (amend): fix: typo\u{1e}\n"
            + "HEAD@{1790180000}\u{1f}4b1b416cccc\u{1f}4b1b416\u{1f}rebase (finish): returning to refs/heads/feat\u{1e}\n"
        let entries = ReflogParser.parse(raw)
        XCTAssertEqual(entries.map(\.selector), ["HEAD@{0}", "HEAD@{1}", "HEAD@{2}"])
        XCTAssertEqual(entries.map(\.kind), ["pull", "amend", "rebase"])
        XCTAssertEqual(entries[1].action, "commit (amend)")
        XCTAssertEqual(entries[1].message, "fix: typo")
        XCTAssertEqual(entries[0].shortHash, "ac4ab04")
        XCTAssertEqual(entries[0].date, Date(timeIntervalSince1970: 1790180042))
    }

    @MainActor
    func testReflogFromRealRepo() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "second"], in: url)
        _ = try await git.run(["commit", "-q", "--amend", "-m", "second amended"], in: url)
        _ = try await git.run(["checkout", "-q", "-b", "feat"], in: url)
        _ = try await git.run(["reset", "-q", "--hard", "HEAD~1"], in: url)

        let entries = await RepositoryStore(url: url).reflog()
        XCTAssertEqual(entries.map(\.kind), ["reset", "checkout", "amend", "commit", "commit"])
        XCTAssertEqual(entries[0].message, "moving to HEAD~1")
        XCTAssertEqual(entries[1].message, "moving from master to feat")
        XCTAssertEqual(entries[2].message, "second amended")
        XCTAssertEqual(entries.last?.action, "commit (initial)")
        XCTAssertLessThan(abs(entries[0].date.timeIntervalSinceNow), 120)
    }

    @MainActor
    func testReflogEmptyRepo() async throws {
        let url = try TestHelpers.makeTempDir()
        _ = try await GitRunner().run(["init", "-q", "-b", "master"], in: url)
        let entries = await RepositoryStore(url: url).reflog()
        XCTAssertEqual(entries, [])
    }

    // MARK: - Reset

    /// init → c2 → c3, plus a staged edit, an unstaged edit, a staged new file and an untracked file.
    private static func makeResetRepo() async throws -> (URL, String) {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let base = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        for name in ["c2", "c3"] {
            try TestHelpers.write("\(name)\n", to: url, "\(name).txt")
            _ = try await git.run(["add", "."], in: url)
            _ = try await git.run(["commit", "-q", "-m", name], in: url)
        }
        try TestHelpers.write("hello\nstaged\n", to: url, "README.md")
        _ = try await git.run(["add", "README.md"], in: url)
        try TestHelpers.write("c2 edited\n", to: url, "c2.txt")
        try TestHelpers.write("new\n", to: url, "new.txt")
        _ = try await git.run(["add", "new.txt"], in: url)
        try TestHelpers.write("u\n", to: url, "untracked.txt")
        return (url, base)
    }

    private static func porcelain(_ url: URL) async throws -> [String] {
        try await GitRunner().run(["status", "--porcelain"], in: url).split(separator: "\n").map(String.init).sorted()
    }

    @MainActor
    func testSoftResetKeepsEverythingStaged() async throws {
        let (url, base) = try await Self.makeResetRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let ok = await store.reset(to: base, mode: .soft, expectedHead: await store.headHash())
        XCTAssertTrue(ok)
        let head = await store.headHash()
        XCTAssertEqual(head, base)
        // Commits' files are staged adds; the unstaged edit on top of the staged c2 add shows as "AM".
        let status = try await Self.porcelain(url)
        XCTAssertEqual(status, ["?? untracked.txt", "A  c3.txt", "A  new.txt", "AM c2.txt", "M  README.md"])
    }

    @MainActor
    func testMixedResetKeepsChangesUnstaged() async throws {
        let (url, base) = try await Self.makeResetRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let ok1 = await store.reset(to: base, mode: .mixed)
        XCTAssertTrue(ok1)
        let status = try await Self.porcelain(url)
        XCTAssertEqual(status, [" M README.md", "?? c2.txt", "?? c3.txt", "?? new.txt", "?? untracked.txt"])
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("c2.txt"), encoding: .utf8), "c2 edited\n")
    }

    @MainActor
    func testHardResetDiscardsTrackedChangesButKeepsUntracked() async throws {
        let (url, base) = try await Self.makeResetRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.repo.filesLostByHardReset.sorted(), ["README.md", "c2.txt", "new.txt"])
        let ok2 = await store.reset(to: base, mode: .hard)
        XCTAssertTrue(ok2)
        let status = try await Self.porcelain(url)
        XCTAssertEqual(status, ["?? untracked.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("new.txt").path))
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8), "hello\n")
        // The undone commits are still reachable from the reflog.
        let reflog = await store.reflog()
        XCTAssertEqual(reflog[0].kind, "reset")
        XCTAssertEqual(reflog[1].message, "c3")
    }

    @MainActor
    func testResetRefusesWhenHeadMoved() async throws {
        let (url, base) = try await Self.makeResetRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let before = await store.headHash()
        let ok = await store.reset(to: base, mode: .hard, expectedHead: base)
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastError)
        let after = await store.headHash()
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testResetImpactCountsPushedCommits() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let base = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        for name in ["p1", "p2", "local"] {
            try TestHelpers.write(name, to: url, name)
            _ = try await git.run(["add", "."], in: url)
            _ = try await git.run(["commit", "-q", "-m", name], in: url)
            if name == "p2" { _ = try await git.run(["update-ref", "refs/remotes/origin/master", "HEAD"], in: url) }
        }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let impact = await store.resetImpact(to: base)
        XCTAssertEqual(impact, ResetImpact(undone: 3, pushed: 2))
        let issues = Preflight.checkReset(repo: store.repo, operation: nil, impact: impact)
        XCTAssertEqual(issues.map(\.id), ["reset-pushed"])
        XCTAssertEqual(issues.first?.severity, .warning)
        let headImpact = await store.resetImpact(to: "HEAD")
        XCTAssertEqual(headImpact, ResetImpact(undone: 0, pushed: 0))
    }

    @MainActor
    func testResetBlockedDuringOperation() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let issues = Preflight.checkReset(repo: store.repo, operation: .rebase, impact: ResetImpact(undone: 1, pushed: 0))
        XCTAssertEqual(issues.map(\.id), ["operation-in-progress"])
        XCTAssertEqual(issues.first?.severity, .blocker)
    }

    // MARK: - Detached HEAD

    @MainActor
    func testDetachedCheckoutLabelAndOrphanWarning() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let base = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestHelpers.write("x", to: url, "x.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "second"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertFalse(store.repo.isDetached)
        XCTAssertEqual(store.repo.branchLabel, "master")

        let ok3 = await store.checkoutDetached(base)
        XCTAssertTrue(ok3)
        XCTAssertTrue(store.repo.isDetached)
        XCTAssertEqual(store.repo.branch, "(detached)")
        XCTAssertEqual(store.repo.branchLabel, "Detached at \(base.prefix(7))")
        let noOrphans = await store.commitsOnlyOnHead()
        XCTAssertEqual(noOrphans, 0)
        XCTAssertNil(Preflight.checkLeavingDetachedHead(repo: store.repo, orphanCount: noOrphans))

        try TestHelpers.write("y", to: url, "y.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "made while detached"], in: url)
        await store.refreshStatus()
        let orphans = await store.commitsOnlyOnHead()
        XCTAssertEqual(orphans, 1)
        XCTAssertEqual(Preflight.checkLeavingDetachedHead(repo: store.repo, orphanCount: orphans)?.id, "detached-orphans")

        // Create Branch Here attaches HEAD and rescues the commit.
        let ok4 = await store.createBranch("rescued")
        XCTAssertTrue(ok4)
        XCTAssertFalse(store.repo.isDetached)
        XCTAssertEqual(store.repo.branch, "rescued")
        let afterRescue = await store.commitsOnlyOnHead()
        XCTAssertEqual(afterRescue, 0)
    }

    @MainActor
    func testCreateBranchAtCommitDoesNotSwitch() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let base = try await GitRunner().run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let ok5 = await store.createBranch("from-reflog", at: base)
        XCTAssertTrue(ok5)
        XCTAssertEqual(store.repo.branch, "master")
        XCTAssertTrue(store.branches.contains { $0.name == "from-reflog" })
        let ok6 = await store.createBranch("from-reflog", at: base)
        XCTAssertFalse(ok6)
        // Real git wording, captured: "fatal: a branch named 'from-reflog' already exists"
        XCTAssertTrue(store.lastError?.stderr.contains("already exists") ?? false)
    }

    func testStatusParserReadsDetachedHead() {
        // Captured from git 2.50.1 after `git checkout <hash>`.
        let status = StatusParser.parse("# branch.oid f433f9f1ee520f733ab64a688a54c3315ee79457\n# branch.head (detached)\n")
        XCTAssertEqual(status.branch, "(detached)")
        XCTAssertEqual(status.headOID, "f433f9f1ee520f733ab64a688a54c3315ee79457")
    }
}
