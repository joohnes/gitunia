import XCTest
@testable import GituniaCore

final class RepositoryStoreTests: XCTestCase {
    @MainActor
    func testRefreshFillsLastCommitAuthorAndHistoryEmail() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.repo.lastCommitAuthor, "Test")
        XCTAssertEqual(store.repo.lastCommitEmail, "test@example.com")
        XCTAssertEqual(store.repo.lastCommitSummary, "init")
        XCTAssertFalse(store.agentProfile.matches(author: "Test", email: "test@example.com"))
        let history = await store.history()
        XCTAssertEqual(history.first?.authorEmail, "test@example.com")
        let byHash = await store.commitInfo(history[0].hash)
        XCTAssertEqual(byHash, history.first, "commitInfo must equal the History row it selects")
    }

    @MainActor
    func testWorkingTreeVersionBumpsOnlyOnRealChange() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let initial = store.workingTreeVersion
        await store.refreshStatus()
        XCTAssertEqual(store.workingTreeVersion, initial, "a no-op refresh isn't a change")
        try TestHelpers.write("hello\nworld\n", to: url, "README.md")
        await store.refreshStatus()
        XCTAssertEqual(store.workingTreeVersion, initial + 1)
        // Already modified, so the fingerprint stays put — the size change still counts.
        try TestHelpers.write("hello\nworld, again\n", to: url, "README.md")
        await store.refreshStatus()
        XCTAssertEqual(store.workingTreeVersion, initial + 2)
        await store.refreshStatus()
        XCTAssertEqual(store.workingTreeVersion, initial + 2)
    }

    @MainActor
    func testStatusStageCommitCycle() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)

        await store.refreshStatus()
        XCTAssertEqual(store.repo.branch, "master")
        XCTAssertTrue(store.repo.changes.isEmpty)
        XCTAssertEqual(store.repo.lastCommitSummary, "init")

        try TestHelpers.write("new\n", to: url, "new.txt")
        try TestHelpers.write("hello\nworld\n", to: url, "README.md")
        await store.refreshStatus()
        XCTAssertEqual(store.untrackedChanges.map(\.path), ["new.txt"])
        XCTAssertEqual(store.unstagedChanges.map(\.path), ["README.md"])

        let untrackedDiff = await store.diff(for: store.untrackedChanges[0])
        XCTAssertEqual(untrackedDiff?.hunks.first?.lines.map(\.text), ["new"])

        await store.stage(store.unstagedChanges[0])
        XCTAssertEqual(store.stagedChanges.map(\.path), ["README.md"])
        let stagedDiff = await store.diff(for: store.stagedChanges[0])
        XCTAssertEqual(stagedDiff?.hunks.first?.lines.filter { $0.kind == .added }.map(\.text), ["world"])

        await store.unstage(store.stagedChanges[0])
        XCTAssertTrue(store.stagedChanges.isEmpty)

        await store.stageAll()
        XCTAssertEqual(Set(store.stagedChanges.map(\.path)), ["README.md", "new.txt"])

        let ai = await store.stagedDiffForAI()
        XCTAssertTrue(ai.stat.contains("2 files changed"))
        XCTAssertTrue(ai.diff.contains("+world"))

        let ok = await store.commit(CommitMessage(title: "feat: add stuff", body: "why"))
        XCTAssertTrue(ok)
        XCTAssertTrue(store.repo.changes.isEmpty)
        XCTAssertEqual(store.repo.lastCommitSummary, "feat: add stuff")
    }

    @MainActor
    func testDiscardModifiedAndUntracked() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("changed\n", to: url, "README.md")
        try TestHelpers.write("tmp\n", to: url, "junk.txt")
        await store.refreshStatus()
        await store.discard(store.unstagedChanges[0])
        await store.discard(store.untrackedChanges[0])
        XCTAssertTrue(store.repo.changes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("junk.txt").path))
    }

    @MainActor
    func testUnstageAll() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("new\n", to: url, "a.txt")
        try TestHelpers.write("changed\n", to: url, "README.md")
        await store.refreshStatus()
        await store.stageAll()
        XCTAssertEqual(store.stagedChanges.count, 2)

        await store.unstageAll()
        XCTAssertTrue(store.stagedChanges.isEmpty)
        XCTAssertEqual(store.unstagedChanges.map(\.path), ["README.md"])
        XCTAssertEqual(store.untrackedChanges.map(\.path), ["a.txt"])
    }

    @MainActor
    func testDiscardAllTrackedLeavesUntrackedFilesOnDisk() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("changed\n", to: url, "README.md")
        try TestHelpers.write("tmp\n", to: url, "junk.txt")
        await store.refreshStatus()

        let ok = await store.discardAllTracked()
        XCTAssertTrue(ok)
        XCTAssertTrue(store.unstagedChanges.isEmpty)
        XCTAssertEqual(store.untrackedChanges.map(\.path), ["junk.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("junk.txt").path))
    }

    // MARK: - C2/L9: pathspec-magic filenames must never leak onto a sibling file

    /// Both files are tracked and modified; acting on `a[1].txt` (a glob-like name) must never
    /// touch `a1.txt`, which without `GIT_LITERAL_PATHSPECS` it would also match.
    @MainActor
    func testStageDoesNotAlsoStageGlobLikeSiblingFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("a1\n", to: url, "a1.txt")
        try TestHelpers.write("bracket\n", to: url, "a[1].txt")
        _ = try await GitRunner().run(["add", "-A"], in: url)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add both"], in: url)
        try TestHelpers.write("a1 changed\n", to: url, "a1.txt")
        try TestHelpers.write("bracket changed\n", to: url, "a[1].txt")

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let bracket = store.unstagedChanges.first { $0.path == "a[1].txt" }!
        await store.stage(bracket)

        XCTAssertEqual(store.stagedChanges.map(\.path), ["a[1].txt"])
        XCTAssertEqual(store.unstagedChanges.map(\.path), ["a1.txt"])
    }

    @MainActor
    func testUnstageDoesNotAlsoUnstageGlobLikeSiblingFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("a1\n", to: url, "a1.txt")
        try TestHelpers.write("bracket\n", to: url, "a[1].txt")
        _ = try await GitRunner().run(["add", "-A"], in: url)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add both"], in: url)
        try TestHelpers.write("a1 changed\n", to: url, "a1.txt")
        try TestHelpers.write("bracket changed\n", to: url, "a[1].txt")
        _ = try await GitRunner().run(["add", "-A"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let bracket = store.stagedChanges.first { $0.path == "a[1].txt" }!
        await store.unstage(bracket)

        XCTAssertEqual(store.unstagedChanges.map(\.path), ["a[1].txt"])
        XCTAssertEqual(store.stagedChanges.map(\.path), ["a1.txt"])
    }

    @MainActor
    func testDiscardDoesNotAlsoRevertGlobLikeSiblingFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("a1\n", to: url, "a1.txt")
        try TestHelpers.write("bracket\n", to: url, "a[1].txt")
        _ = try await GitRunner().run(["add", "-A"], in: url)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add both"], in: url)
        try TestHelpers.write("a1 changed\n", to: url, "a1.txt")
        try TestHelpers.write("bracket changed\n", to: url, "a[1].txt")

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let bracket = store.unstagedChanges.first { $0.path == "a[1].txt" }!
        await store.discard(bracket)

        let bracketContent = try String(contentsOf: url.appendingPathComponent("a[1].txt"), encoding: .utf8)
        let a1Content = try String(contentsOf: url.appendingPathComponent("a1.txt"), encoding: .utf8)
        XCTAssertEqual(bracketContent, "bracket\n")
        XCTAssertEqual(a1Content, "a1 changed\n")
        XCTAssertEqual(store.unstagedChanges.map(\.path), ["a1.txt"])
    }

    @MainActor
    func testRestoreFileDoesNotAlsoRestoreGlobLikeSiblingFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("a1 v1\n", to: url, "a1.txt")
        try TestHelpers.write("bracket v1\n", to: url, "a[1].txt")
        let git = GitRunner()
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "v1"], in: url)
        let firstCommit = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestHelpers.write("a1 v2\n", to: url, "a1.txt")
        try TestHelpers.write("bracket v2\n", to: url, "a[1].txt")
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "v2"], in: url)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let ok = await store.restoreFile("a[1].txt", from: firstCommit)
        XCTAssertTrue(ok)

        let bracketContent = try String(contentsOf: url.appendingPathComponent("a[1].txt"), encoding: .utf8)
        let a1Content = try String(contentsOf: url.appendingPathComponent("a1.txt"), encoding: .utf8)
        XCTAssertEqual(bracketContent, "bracket v1\n")
        XCTAssertEqual(a1Content, "a1 v2\n")
    }

    // MARK: - H1: status must not rewrite the index

    /// `git status` opportunistically refreshes and rewrites `.git/index`'s stat cache when a
    /// tracked file's mtime looks stale — which then fires FSEvents and triggers another refresh.
    /// `--no-optional-locks` (set on every call by `GitRunner`) must prevent that write.
    @MainActor
    func testRefreshStatusDoesNotRewriteGitIndex() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let indexPath = url.appendingPathComponent(".git/index").path
        let before = try FileManager.default.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date

        // Touch the tracked file's mtime (without changing its content) — the scenario that makes
        // plain `git status` decide to refresh the index's stat cache.
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: future],
                                               ofItemAtPath: url.appendingPathComponent("README.md").path)

        await store.refreshStatus()
        let after = try FileManager.default.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    @MainActor
    func testCommitFailureSetsLastError() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let ok = await store.commit(CommitMessage(title: "nothing staged"))
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testUnicodeAndSpacePathsRoundTrip() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let name = "zażółć gęślą.txt"

        try TestHelpers.write("hello\n", to: url, name)
        await store.refreshStatus()
        XCTAssertEqual(store.untrackedChanges.map(\.path), [name])

        let diff = await store.diff(for: store.untrackedChanges[0])
        XCTAssertEqual(diff?.hunks.first?.lines.map(\.text), ["hello"])

        await store.stage(store.untrackedChanges[0])
        XCTAssertEqual(store.stagedChanges.map(\.path), [name])

        let ok = await store.commit(CommitMessage(title: "add unicode file"))
        XCTAssertTrue(ok)
        XCTAssertTrue(store.repo.changes.isEmpty)
    }

    @MainActor
    func testUntrackedDirectoryListsEachFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("newdir"), withIntermediateDirectories: true)
        try TestHelpers.write("a\n", to: url, "newdir/a.txt")
        try TestHelpers.write("b\n", to: url, "newdir/b.txt")

        await store.refreshStatus()
        XCTAssertEqual(store.untrackedChanges.map(\.path).sorted(), ["newdir/a.txt", "newdir/b.txt"])

        let diff = await store.diff(for: store.untrackedChanges.sorted { $0.path < $1.path }[0])
        XCTAssertNotNil(diff)
        XCTAssertFalse(diff?.hunks.isEmpty ?? true)
    }

    @MainActor
    func testLastErrorClearsOnNextSuccessfulAction() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        let ok = await store.commit(CommitMessage(title: "x"))
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastError)

        try TestHelpers.write("new\n", to: url, "new.txt")
        await store.stageAll()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.stagedChanges.count, 1)
    }

    @MainActor
    func testStageAndUnstageSingleHunk() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let original = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try TestHelpers.write(original, to: url, "big.txt")
        _ = try await git.run(["add", "big.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "base"], in: url)

        var lines = original.split(separator: "\n").map(String.init)
        lines[1] = "line 2 changed"
        lines[35] = "line 36 changed"
        try TestHelpers.write(lines.joined(separator: "\n") + "\n", to: url, "big.txt")

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let change = store.unstagedChanges[0]
        let diff = await store.diff(for: change)!
        XCTAssertEqual(diff.hunks.count, 2)

        let staged1 = await store.stageHunk(diff.hunks[0], of: change)
        XCTAssertTrue(staged1)
        XCTAssertEqual(store.stagedChanges.map(\.path), ["big.txt"])
        XCTAssertEqual(store.unstagedChanges.map(\.path), ["big.txt"])
        let staged = await store.diff(for: store.stagedChanges[0])!
        XCTAssertEqual(staged.hunks.count, 1)
        XCTAssertTrue(staged.hunks[0].lines.contains { $0.text == "line 2 changed" })

        let unstaged1 = await store.unstageHunk(staged.hunks[0], of: store.stagedChanges[0])
        XCTAssertTrue(unstaged1)
        XCTAssertTrue(store.stagedChanges.isEmpty)
        let unstaged = await store.diff(for: store.unstagedChanges[0])!
        XCTAssertEqual(unstaged.hunks.count, 2)
    }

    @MainActor
    func testDiffWithContextReturnsWholeFileAsOneHunk() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let original = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try TestHelpers.write(original, to: url, "big.txt")
        _ = try await git.run(["add", "big.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "base"], in: url)

        var lines = original.split(separator: "\n").map(String.init)
        lines[1] = "line 2 changed"
        lines[35] = "line 36 changed"
        try TestHelpers.write(lines.joined(separator: "\n") + "\n", to: url, "big.txt")

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let change = store.unstagedChanges[0]

        // Default (small) context still splits into two hunks around each edit.
        let normal = await store.diff(for: change)!
        XCTAssertEqual(normal.hunks.count, 2)

        // A huge -U context collapses the whole file into a single hunk with full context.
        let whole = await store.diff(for: change, context: 100000)!
        XCTAssertEqual(whole.hunks.count, 1)
        // 38 unchanged context lines + both old/new versions of the 2 changed lines.
        XCTAssertEqual(whole.hunks[0].lines.count, 42)
        XCTAssertTrue(whole.hunks[0].lines.contains { $0.text == "line 1" })
        XCTAssertTrue(whole.hunks[0].lines.contains { $0.text == "line 40" })
        XCTAssertTrue(whole.hunks[0].lines.contains { $0.text == "line 2 changed" && $0.kind == .added })
    }

    @MainActor
    func testDiffWithContextOnUntrackedFileStillShowsWholeFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("a\nb\nc\n", to: url, "new.txt")
        await store.refreshStatus()

        let whole = await store.diff(for: store.untrackedChanges[0], context: 100000)!
        XCTAssertEqual(whole.hunks.first?.lines.map(\.text), ["a", "b", "c"])
    }

    // MARK: - Amend

    @MainActor
    func testAmendReplacesRatherThanAddsACommit() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let before = await store.history()
        XCTAssertEqual(before.count, 1)

        let ok = await store.commit(CommitMessage(title: "reworded message"), amend: true)
        XCTAssertTrue(ok)

        let after = await store.history()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].subject, "reworded message")
        XCTAssertNotEqual(after[0].hash, before[0].hash)
    }

    @MainActor
    func testAmendFoldsNewlyStagedChangesIntoPreviousCommit() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        try TestHelpers.write("hello\nmore\n", to: url, "README.md")
        await store.stageAll()
        let ok = await store.commit(CommitMessage(title: "init"), amend: true)
        XCTAssertTrue(ok)

        let history = await store.history()
        XCTAssertEqual(history.count, 1)
        let diffs = await store.commitDiff(history[0].hash)
        XCTAssertTrue(diffs.first?.hunks.first?.lines.contains { $0.text == "more" && $0.kind == .added } ?? false)
    }

    @MainActor
    func testAmendOnEmptyRepoFailsCleanly() async throws {
        let url = try await TestRepo.make(commit: false)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertNil(store.repo.lastCommitSummary)

        let ok = await store.commit(CommitMessage(title: "amend with no history"), amend: true)
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastError)
    }

    // MARK: - Reword HEAD

    @MainActor
    func testRewordHead_changesMessageKeepsTreeAndLeavesStagedChangesStaged() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("staged\n", to: url, "staged.txt")
        _ = try await git.run(["add", "staged.txt"], in: url)
        await store.refreshStatus()
        let treeBefore = try await git.run(["rev-parse", "HEAD^{tree}"], in: url)

        let ok = await store.rewordHead(CommitMessage(title: "feat: better", body: "why\n\nCo-Authored-By: Bot <noreply@anthropic.com>"),
                                        stripTrailers: true)
        XCTAssertTrue(ok)
        let last = await store.lastCommitMessage()
        XCTAssertEqual(last?.title, "feat: better")
        XCTAssertEqual(last?.body, "why", "trailer stripped")
        let treeAfter = try await git.run(["rev-parse", "HEAD^{tree}"], in: url)
        XCTAssertEqual(treeBefore, treeAfter)
        let staged = try await git.run(["diff", "--cached", "--name-only"], in: url)
        XCTAssertEqual(staged.trimmingCharacters(in: .whitespacesAndNewlines), "staged.txt")
        let history = await store.history()
        XCTAssertEqual(history.count, 1)
    }

    @MainActor
    func testRewordHead_refusesMidOperation() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        let head = try await git.run(["rev-parse", "HEAD"], in: url)
        try head.write(to: url.appendingPathComponent(".git/MERGE_HEAD"), atomically: true, encoding: .utf8)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .merge)

        let ok = await store.rewordHead(CommitMessage(title: "nope"), stripTrailers: false)
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastError)
        let last = await store.lastCommitMessage()
        XCTAssertEqual(last?.title, "init")
    }

    /// An agent committing while the Reword sheet / Amend toggle is open must not get its commit
    /// rewritten with a message meant for the one the user looked at.
    @MainActor
    func testRewordAndAmendRefuseWhenHeadMoved() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        let last0 = await store.lastCommit()
        let seen = try XCTUnwrap(last0)
        XCTAssertEqual(seen.message.title, "init")
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "agent"], in: url)

        let reworded = await store.rewordHead(CommitMessage(title: "mine"), stripTrailers: false, expectedHead: seen.hash)
        XCTAssertFalse(reworded)
        XCTAssertNotNil(store.lastError)
        let amended = await store.commit(CommitMessage(title: "mine"), amend: true, expectedHead: seen.hash)
        XCTAssertFalse(amended)
        let last = await store.lastCommitMessage()
        XCTAssertEqual(last?.title, "agent")
    }

    // MARK: - lastCommitMessage

    @MainActor
    func testLastCommitMessageRoundTripsTitleAndBody() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let ok = await store.commit(CommitMessage(title: "feat: add thing", body: "why it matters\n\nmore detail"), amend: true)
        XCTAssertTrue(ok)

        let last = await store.lastCommitMessage()
        XCTAssertEqual(last?.title, "feat: add thing")
        XCTAssertEqual(last?.body, "why it matters\n\nmore detail")
    }

    @MainActor
    func testLastCommitMessageReturnsNilOnEmptyRepo() async throws {
        let url = try TestHelpers.makeTempDir()
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master"], in: url)
        let store = RepositoryStore(url: url)
        let last = await store.lastCommitMessage()
        XCTAssertNil(last)
    }

    // MARK: - undoLastCommit

    @MainActor
    func testUndoLastCommitRestoresChangesAsStaged() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertFalse(store.hasParentCommit) // single "init" commit so far

        try TestHelpers.write("hello\nmore\n", to: url, "README.md")
        try TestHelpers.write("new\n", to: url, "new.txt")
        await store.stageAll()
        let committed = await store.commit(CommitMessage(title: "add stuff"))
        XCTAssertTrue(committed)
        let historyAfterCommit = await store.history()
        XCTAssertEqual(historyAfterCommit.count, 2)
        XCTAssertTrue(store.hasParentCommit)

        let ok = await store.undoLastCommit()
        XCTAssertTrue(ok)

        let historyAfterUndo = await store.history()
        XCTAssertEqual(historyAfterUndo.count, 1)
        // The undone commit's changes land back in the index — staged, not unstaged or gone.
        XCTAssertEqual(Set(store.stagedChanges.map(\.path)), ["README.md", "new.txt"])
        XCTAssertTrue(store.unstagedChanges.isEmpty)
    }

    @MainActor
    func testUndoLastCommitOnRootCommitFailsCleanlyWithoutCorruptingTheRepo() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertFalse(store.hasParentCommit)

        // A fresh repo from `makeTempRepo` has exactly one commit, so HEAD~1 doesn't resolve —
        // reset --soft HEAD~1 must fail rather than silently doing something else.
        let root = try await GitRunner().run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)

        let ok = await store.undoLastCommit()
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastError)

        // The repo is still usable: HEAD is unchanged and a normal status/commit cycle still works.
        let headAfter = try await GitRunner().run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(headAfter, root)
        await store.refreshStatus()
        XCTAssertEqual(store.repo.lastCommitSummary, "init")
        try TestHelpers.write("x\n", to: url, "x.txt")
        await store.stageAll()
        let stillWorks = await store.commit(CommitMessage(title: "still works"))
        XCTAssertTrue(stillWorks)
    }

    @MainActor
    func testUndoLastCommitRoundTripLeavesTreeEquivalent() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        try TestHelpers.write("hello\nmore\n", to: url, "README.md")
        await store.stageAll()
        let firstCommit = await store.commit(CommitMessage(title: "tweak readme"))
        XCTAssertTrue(firstCommit)
        let treeBefore = try await GitRunner().run(["rev-parse", "HEAD^{tree}"], in: url)

        let undone = await store.undoLastCommit()
        XCTAssertTrue(undone)
        XCTAssertEqual(store.stagedChanges.map(\.path), ["README.md"])

        let secondCommit = await store.commit(CommitMessage(title: "tweak readme again"))
        XCTAssertTrue(secondCommit)
        let treeAfter = try await GitRunner().run(["rev-parse", "HEAD^{tree}"], in: url)
        XCTAssertEqual(treeBefore, treeAfter)
    }

    @MainActor
    func testHasParentCommitFalseOnRootCommit() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertFalse(store.hasParentCommit)

        try TestHelpers.write("x\n", to: url, "x.txt")
        await store.stageAll()
        let committed = await store.commit(CommitMessage(title: "second"))
        XCTAssertTrue(committed)
        XCTAssertTrue(store.hasParentCommit)

        let undone = await store.undoLastCommit()
        XCTAssertTrue(undone)
        XCTAssertFalse(store.hasParentCommit)
    }

    /// The gap between History's confirmation dialog and the reset: if an agent commits into the
    /// repo meanwhile, undoing must refuse rather than silently drop the newer commit.
    @MainActor
    func testUndoLastCommitRefusesWhenHeadMovedSinceConfirmation() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("a\n", to: url, "a.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "the one the user saw"))
        let seenHead = try await GitRunner().run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)

        try TestHelpers.write("b\n", to: url, "b.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "an agent got there first"))

        let undone = await store.undoLastCommit(expectedHead: seenHead)
        XCTAssertFalse(undone)
        XCTAssertNotNil(store.lastError)
        await store.refreshStatus()
        XCTAssertEqual(store.repo.lastCommitSummary, "an agent got there first")

        let forced = await store.undoLastCommit(expectedHead: nil)
        XCTAssertTrue(forced)
        await store.refreshStatus()
        XCTAssertEqual(store.repo.lastCommitSummary, "the one the user saw")
    }

    // MARK: - Stash

    @MainActor
    func testStashThenPopRoundTripsDirtyTreeIncludingUntracked() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        try TestHelpers.write("hello\nmodified\n", to: url, "README.md")
        try TestHelpers.write("new file\n", to: url, "untracked.txt")
        await store.refreshStatus()
        XCTAssertEqual(Set(store.repo.changes.map(\.path)), ["README.md", "untracked.txt"])

        let stashed = await store.stash()
        XCTAssertTrue(stashed)
        // The tree really is clean afterwards, including the untracked file (needs `-u`).
        XCTAssertTrue(store.repo.changes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("untracked.txt").path))
        XCTAssertEqual(store.stashCount, 1)

        let popped = await store.stashPop()
        XCTAssertTrue(popped)
        XCTAssertEqual(Set(store.repo.changes.map(\.path)), ["README.md", "untracked.txt"])
        XCTAssertEqual(store.stashCount, 0)
        let restored = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(restored, "hello\nmodified\n")
        let restoredUntracked = try String(contentsOf: url.appendingPathComponent("untracked.txt"), encoding: .utf8)
        XCTAssertEqual(restoredUntracked, "new file\n")
    }

    @MainActor
    func testStashOnCleanTreeIsANoOpNotAnError() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertTrue(store.repo.changes.isEmpty)

        let stashed = await store.stash()
        XCTAssertFalse(stashed)
        XCTAssertNil(store.lastError, "a clean-tree no-op is not a failure")
        XCTAssertEqual(store.stashCount, 0)
    }

    @MainActor
    func testStashCountUpdatesAcrossStashAndPop() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.stashCount, 0)

        try TestHelpers.write("one\n", to: url, "README.md")
        let firstStash = await store.stash()
        XCTAssertTrue(firstStash)
        XCTAssertEqual(store.stashCount, 1)

        try TestHelpers.write("two\n", to: url, "README.md")
        let secondStash = await store.stash()
        XCTAssertTrue(secondStash)
        XCTAssertEqual(store.stashCount, 2)

        let popped = await store.stashPop()
        XCTAssertTrue(popped)
        XCTAssertEqual(store.stashCount, 1)
    }

    @MainActor
    func testConflictingPopReportsFailureNotSuccess() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()

        // Stash a change to README.md, then commit a conflicting change to the same line, so
        // popping the stash produces a real merge conflict rather than git's "would be
        // overwritten" pre-check.
        try TestHelpers.write("hello\nstashed-version\n", to: url, "README.md")
        let stashed = await store.stash(message: "conflict source")
        XCTAssertTrue(stashed)

        try TestHelpers.write("hello\ncommitted-version\n", to: url, "README.md")
        await store.stageAll()
        let committed = await store.commit(CommitMessage(title: "conflicting commit"))
        XCTAssertTrue(committed)

        let popped = await store.stashPop()
        XCTAssertFalse(popped)
        XCTAssertNotNil(store.lastError)
        // The stash is kept on a failed pop (git's own behavior) so nothing was lost.
        XCTAssertEqual(store.stashCount, 1)

        // Real conflict markers, not silently resolved either way.
        let conflicted = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(conflicted.contains("<<<<<<<"))

        // Clean up so the temp dir doesn't linger in a conflicted git state.
        _ = try? await git.run(["checkout", "--ours", "--", "README.md"], in: url)
        _ = try? await git.run(["add", "README.md"], in: url)
    }

    // MARK: - Conflict handling (Task D1)

    /// Two branches editing the same line of `README.md`, merged into a real conflict. Returns
    /// the repo URL with `master` checked out and mid-merge, `feature` unmerged.
    @MainActor
    private func makeConflictedMergeRepo() async throws -> URL {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try TestHelpers.write("hello\nfeature-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "feature change"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("hello\nmain-line\n", to: url, "README.md")
        _ = try await git.run(["commit", "-q", "-am", "master change"], in: url)
        // Exits 1 on conflict — that's the expected outcome here, not a test failure.
        _ = try? await git.run(["merge", "-q", "feature"], in: url, allowedExitCodes: [0, 1])
        return url
    }

    @MainActor
    func testMergeInProgressDetectedDuringConflictAndClearedAfterAbort() async throws {
        let url = try await makeConflictedMergeRepo()
        let store = RepositoryStore(url: url)

        await store.refreshStatus()
        XCTAssertEqual(store.operation, .merge)
        XCTAssertFalse(store.rebaseInProgress)
        XCTAssertEqual(store.conflictedChanges.map(\.path), ["README.md"])

        let aborted = await store.abortMerge()
        XCTAssertTrue(aborted)
        XCTAssertNotEqual(store.operation, .merge)
        XCTAssertTrue(store.conflictedChanges.isEmpty)
    }

    @MainActor
    func testAbortMergeRestoresPreMergeContent() async throws {
        let url = try await makeConflictedMergeRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .merge)

        _ = await store.abortMerge()

        let content = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(content, "hello\nmain-line\n")
        XCTAssertFalse(content.contains("<<<<<<<"))
    }

    @MainActor
    func testUseOursKeepsCurrentBranchContentAndStagesIt() async throws {
        let url = try await makeConflictedMergeRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let conflicted = store.conflictedChanges[0]

        let ok = await store.useOurs(conflicted)
        XCTAssertTrue(ok)

        let content = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(content, "hello\nmain-line\n")
        // Resolved: no longer conflicted. Not staged as a *change*, because "ours" here is
        // exactly HEAD's own content — `git add` ran, but the resulting blob is identical to
        // HEAD's, so there's no diff left for `git status` to report (verified against real git
        // above: this is expected, not a bug in `useOurs`).
        XCTAssertTrue(store.conflictedChanges.isEmpty)
        XCTAssertTrue(store.repo.changes.isEmpty)
    }

    @MainActor
    func testUseTheirsKeepsIncomingBranchContentAndStagesIt() async throws {
        let url = try await makeConflictedMergeRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let conflicted = store.conflictedChanges[0]

        let ok = await store.useTheirs(conflicted)
        XCTAssertTrue(ok)

        let content = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(content, "hello\nfeature-line\n")
        XCTAssertTrue(store.conflictedChanges.isEmpty)
        XCTAssertEqual(store.stagedChanges.map(\.path), ["README.md"])
    }

    @MainActor
    func testMergeInProgressFalseAfterResolutionAndCommit() async throws {
        let url = try await makeConflictedMergeRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.operation, .merge)

        _ = await store.useOurs(store.conflictedChanges[0])
        let committed = await store.commit(CommitMessage(title: "merge feature"))
        XCTAssertTrue(committed)
        XCTAssertNotEqual(store.operation, .merge)
    }

    @MainActor
    func testMergeInProgressFalseOnOrdinaryRepo() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertNotEqual(store.operation, .merge)
        XCTAssertFalse(store.rebaseInProgress)
    }

    /// Mirrors `WorkspaceStore.handleChanges`'s FSEvents debounce: a `Task` running `refreshStatus()`
    /// gets cancelled mid-flight (e.g. by a newer debounced refresh superseding it). `refreshStatus`
    /// must treat `CancellationError` as silent — not surface it as `lastError`, which would pop a
    /// spurious error toast for something that isn't a real failure.
    @MainActor
    func testRefreshStatusCancellationLeavesLastErrorNil() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)

        let task = Task { await store.refreshStatus() }
        task.cancel()
        await task.value

        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testRefreshStatusReportsHeadMovedByOutsideCommit() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        var received: [RepoEvent] = []
        store.onEvents = { received += $0 }
        await store.refreshStatus()
        XCTAssertTrue(received.isEmpty, "first load has nothing to diff against")

        _ = try await GitRunner().run(["commit", "-q", "--allow-empty", "-m", "agent work"], in: url)
        await store.refreshStatus()
        XCTAssertEqual(received.count, 1)
        guard case .headMoved(let from, let to) = received.first else { return XCTFail("\(received)") }
        XCTAssertNotEqual(from, to)
        XCTAssertEqual(to, store.repo.headOID)
    }

    @MainActor
    func testRefreshStatusFillsSizeForUntrackedAndNilForDeleted() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("12345", to: url, "new.txt")
        try FileManager.default.removeItem(at: url.appendingPathComponent("README.md"))
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertEqual(store.repo.changes.first { $0.path == "new.txt" }?.size, 5)
        let deleted = try XCTUnwrap(store.repo.changes.first { $0.path == "README.md" })
        XCTAssertEqual(deleted.status, .deleted)
        XCTAssertNil(deleted.size)
    }

    /// docs/next-round-plan.md A2: `isBusy` is a counter now, so the first of two overlapping
    /// operations to finish must not clear it while the other is still running.
    @MainActor
    func testIsBusyStaysTrueUntilAllOverlappingOperationsFinish() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        XCTAssertFalse(store.isBusy)

        async let shorter: Void = { @MainActor in
            store.beginBusy()
            try? await Task.sleep(for: .milliseconds(100))
            store.endBusy()
        }()
        async let longer: Void = { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            store.beginBusy()
            try? await Task.sleep(for: .milliseconds(200))
            store.endBusy()
        }()

        try await Task.sleep(for: .milliseconds(130))
        XCTAssertTrue(store.isBusy, "the shorter operation finished but the longer one is still in flight")
        _ = await (shorter, longer)
        XCTAssertFalse(store.isBusy, "both operations finished")
    }
}
