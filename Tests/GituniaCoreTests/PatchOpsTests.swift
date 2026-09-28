import XCTest
@testable import GituniaCore

@MainActor
final class PatchOpsTests: XCTestCase {
    private let git = GitRunner()

    private func makeRepo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-patch-\(UUID().uuidString)")
        try await TestRepo.make(at: url, commit: false, user: "T", email: "t@example.com")
        try await commitAsync(url, "a.txt", "one\ntwo\nthree\n", message: "init")
        return url
    }

    private func write(_ url: URL, _ name: String, _ text: String) throws {
        try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commitAsync(_ url: URL, _ name: String, _ text: String, message: String,
                             author: String = "T <t@example.com>") async throws {
        try write(url, name, text)
        _ = try await git.run(["add", name], in: url)
        _ = try await git.run(["commit", "-q", "--author", author, "-m", message], in: url)
    }

    /// A repo with `init`, plus a second commit on top whose mailbox patch is returned; HEAD is
    /// then reset back to `init` so the patch can be re-applied.
    private func repoWithPatch() async throws -> (URL, RepositoryStore, String) {
        let url = try await makeRepo()
        try await commitAsync(url, "a.txt", "one\nTWO\nthree\n", message: "Fix: shout two!", author: "Ada L <ada@example.com>")
        let store = RepositoryStore(url: url)
        let hash = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .newlines)
        let patches = await store.formatPatch([hash])
        XCTAssertEqual(patches.count, 1)
        _ = try await git.run(["reset", "-q", "--hard", "HEAD~1"], in: url)
        await store.refreshStatus()
        return (url, store, patches[0].contents)
    }

    func testExport_mailboxWithSubjectAndGitName() async throws {
        let (_, _, patch) = try await repoWithPatch()
        XCTAssertTrue(patch.hasPrefix("From "))
        XCTAssertTrue(patch.contains("Subject: [PATCH] Fix: shout two!"))
        XCTAssertTrue(PatchCheck.isMailbox(patch))
    }

    func testSlug_matchesGit() {
        XCTAssertEqual(RepositoryStore.patchFileName(subject: "Add Feature: foo/bar!!  baz..."), "0001-Add-Feature-foo-bar-baz.patch")
        XCTAssertEqual(RepositoryStore.patchFileName(subject: "Zażółć gęślą_jaźń v1.2..3", number: 3), "0003-Za-g-l-_ja-v1.2.3.patch")
        XCTAssertEqual(RepositoryStore.patchFileName(subject: "...Leading dots and a very long subject line that goes on and on and on forever ok"),
                       "0001-.Leading-dots-and-a-very-long-subject-line-that-goes.patch")
        XCTAssertEqual(RepositoryStore.patchFileName(subject: String(repeating: "a", count: 51) + " bcd"),
                       "0001-" + String(repeating: "a", count: 51) + "-.patch")
    }

    func testCheck_cleanVersusConflicting() async throws {
        let (url, store, patch) = try await repoWithPatch()
        let ok = await store.checkPatch(patch)
        XCTAssertTrue(ok.applies, ok.message)
        XCTAssertEqual(ok.touchedFiles, ["a.txt"])
        XCTAssertTrue(ok.message.hasPrefix("Applies cleanly — 1 file: a.txt"))
        try write(url, "a.txt", "completely\ndifferent\n")
        let bad = await store.checkPatch(patch)
        XCTAssertFalse(bad.applies)
        XCTAssertTrue(bad.message.contains("a.txt"), bad.message)
    }

    func testApplyAsCommits_recreatesCommitWithAuthor() async throws {
        let (url, store, patch) = try await repoWithPatch()
        let error = await store.applyPatch(patch, asCommits: true, threeWay: false)
        XCTAssertNil(error)
        let log = try await git.run(["log", "-1", "--format=%s|%an <%ae>"], in: url)
        XCTAssertEqual(log.trimmingCharacters(in: .newlines), "Fix: shout two!|Ada L <ada@example.com>")
    }

    func testApplyToWorkingTree_changesFilesNoCommit() async throws {
        let (url, store, patch) = try await repoWithPatch()
        let before = try await git.run(["rev-parse", "HEAD"], in: url)
        let error = await store.applyPatch(patch, asCommits: false, threeWay: false)
        XCTAssertNil(error)
        let after = try await git.run(["rev-parse", "HEAD"], in: url)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8), "one\nTWO\nthree\n")
        let staged = try await git.run(["diff", "--cached", "--name-only"], in: url)
        XCTAssertEqual(staged, "", "left unstaged for review")
    }

    func testAmFailure_isAborted() async throws {
        let (url, store, patch) = try await repoWithPatch()
        try await commitAsync(url, "a.txt", "nothing\nalike\n", message: "diverge")
        let error = await store.applyPatch(patch, asCommits: true, threeWay: false)
        XCTAssertNotNil(error)
        XCTAssertNil(store.operation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent(".git/rebase-apply").path))
    }

    func testApply_refusedMidOperation() async throws {
        let (url, store, patch) = try await repoWithPatch()
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        await store.refreshStatus()
        let error = await store.applyPatch(patch, asCommits: false, threeWay: false)
        XCTAssertEqual(error?.exitCode, -1)
    }

    func testDiffPatch_untruncatedRoundTrip() async throws {
        let (url, store, _) = try await repoWithPatch()
        try write(url, "a.txt", "one\ntwo\nthree\nfour\n")
        let diff = await store.diffPatch(staged: false)
        XCTAssertTrue(diff.contains("+four"))
        let staged = await store.diffPatch(staged: true)
        XCTAssertEqual(staged, "")
    }
}
