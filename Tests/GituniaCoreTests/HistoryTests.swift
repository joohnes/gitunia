import XCTest
@testable import GituniaCore

final class HistoryTests: XCTestCase {
    @MainActor
    func testHistoryAndCommitDiff() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("a\n", to: url, "a.txt")
        try TestHelpers.write("b\n", to: url, "b.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "feat: two files"))

        let history = await store.history()
        XCTAssertEqual(history.map(\.subject), ["feat: two files", "init"])
        XCTAssertEqual(history[0].author, "Test")

        let files = await store.commitDiff(history[0].hash)
        XCTAssertEqual(files.map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(files[0].hunks[0].lines.map(\.kind), [.added])
    }

    @MainActor
    func testMergeCommitDiffShowsFirstParentChanges() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()

        _ = try await git.run(["checkout", "-q", "-b", "feat"], in: url)
        try TestHelpers.write("f\n", to: url, "f.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "feat: f"))

        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("m\n", to: url, "m.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "chore: m"))

        _ = try await git.run(["merge", "-q", "--no-ff", "-m", "merge feat", "feat"], in: url)

        let history = await store.history()
        XCTAssertEqual(history[0].subject, "merge feat")

        let files = await store.commitDiff(history[0].hash)
        XCTAssertEqual(files.map(\.path), ["f.txt"])
    }

    // MARK: - Filter (HistoryFilter.gitArgs against real git)

    @MainActor
    func testFilterByAuthor() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "alice's commit", "--author=Alice <alice@x.com>"], in: url)
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "bob's commit", "--author=Bob <bob@x.com>"], in: url)

        let filter = HistoryFilter.parse("author:alice")
        let history = await store.history(filterArgs: filter.gitArgs)
        XCTAssertEqual(history.map(\.subject), ["alice's commit"])
    }

    @MainActor
    func testFilterByPath() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "touch a"], in: url)
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "touch b"], in: url)

        let filter = HistoryFilter.parse("path:a.txt")
        let history = await store.history(filterArgs: filter.gitArgs)
        XCTAssertEqual(history.map(\.subject), ["touch a"])
    }

    @MainActor
    func testFilterBySinceUntil() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        setenv("GIT_AUTHOR_DATE", "2020-01-01T12:00:00", 1)
        setenv("GIT_COMMITTER_DATE", "2020-01-01T12:00:00", 1)
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "old commit"], in: url)
        setenv("GIT_AUTHOR_DATE", "2025-06-01T12:00:00", 1)
        setenv("GIT_COMMITTER_DATE", "2025-06-01T12:00:00", 1)
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "new commit"], in: url)
        unsetenv("GIT_AUTHOR_DATE"); unsetenv("GIT_COMMITTER_DATE")

        let filter = HistoryFilter.parse("since:2025-01-01")
        let history = await store.history(filterArgs: filter.gitArgs)
        XCTAssertEqual(history.map(\.subject), ["new commit"])

        let untilFilter = HistoryFilter.parse("until:2020-06-01")
        let untilHistory = await store.history(filterArgs: untilFilter.gitArgs)
        XCTAssertEqual(untilHistory.map(\.subject), ["old commit"])
    }

    @MainActor
    func testFilterByGrepAcrossBody() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "fix: thing\n\nContains needle in the body"], in: url)
        try TestHelpers.write("b\n", to: url, "b.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "chore: other"], in: url)

        let filter = HistoryFilter.parse("needle")
        let history = await store.history(filterArgs: filter.gitArgs)
        XCTAssertEqual(history.map(\.subject), ["fix: thing"])
    }

    @MainActor
    func testFilterAllMatchRequiresEveryWord() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "fix bug in parser"], in: url)
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "fix bug in renderer"], in: url)
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "fix typo"], in: url)

        let filter = HistoryFilter.parse("fix bug")
        let history = await store.history(filterArgs: filter.gitArgs)
        XCTAssertEqual(history.map(\.subject).sorted(), ["fix bug in parser", "fix bug in renderer"])
    }

    // MARK: - Agent author filter (B8, against real git)

    /// The "Agent commits" chip's filter (`AgentProfile.gitAuthorArgs`) must apply in git itself,
    /// not just to whatever page is already loaded — verified here by paging with `limit: 1` past
    /// a human commit sitting between two bot commits.
    @MainActor
    func testGitAuthorArgsFiltersAcrossPages() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "bot commit 1", "--author=Bot <bot@example.com>"], in: url)
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "human commit", "--author=Human <human@example.com>"], in: url)
        _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "bot commit 2", "--author=Bot <bot@example.com>"], in: url)

        let profile = AgentProfile(patterns: ["bot@example.com"])
        let page1 = await store.history(limit: 1, skip: 0, filterArgs: profile.gitAuthorArgs)
        XCTAssertEqual(page1.map(\.subject), ["bot commit 2"])
        // skip: 1 within the *filtered* range — the human commit in between must not consume a slot.
        let page2 = await store.history(limit: 1, skip: 1, filterArgs: profile.gitAuthorArgs)
        XCTAssertEqual(page2.map(\.subject), ["bot commit 1"])
    }

    // MARK: - Paging

    @MainActor
    func testPagingBoundaries() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        // init + 449 more = 450 commits total.
        for i in 1...449 {
            _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "commit \(i)"], in: url)
        }

        let page1 = await store.history(limit: 200, skip: 0)
        XCTAssertEqual(page1.count, 200)
        XCTAssertEqual(page1.first?.subject, "commit 449")

        let page2 = await store.history(limit: 200, skip: 200)
        XCTAssertEqual(page2.count, 200)
        XCTAssertEqual(Set(page1.map(\.hash)).intersection(page2.map(\.hash)), [])

        let page3 = await store.history(limit: 200, skip: 400)
        XCTAssertEqual(page3.count, 50) // 450 total - 400 already loaded
        XCTAssertEqual(page3.last?.subject, "init")
    }

    // MARK: - Commit detail

    @MainActor
    func testCommitDetailMultiLineBodyAndAuthorNotCommitter() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        try TestHelpers.write("a\n", to: url, "a.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feat: thing\n\nLine one.\nLine two.", "--author=Alice <alice@x.com>"], in: url)
        let hash = (try await git.run(["rev-parse", "HEAD"], in: url)).trimmingCharacters(in: .whitespacesAndNewlines)

        let detail = await store.commitDetail(hash)
        XCTAssertEqual(detail?.subject, "feat: thing")
        XCTAssertEqual(detail?.body, "Line one.\nLine two.")
        XCTAssertEqual(detail?.authorName, "Alice")
        XCTAssertEqual(detail?.authorEmail, "alice@x.com")
        XCTAssertEqual(detail?.committerName, "Test")
        XCTAssertTrue(detail?.committerDiffersFromAuthor ?? false)
        XCTAssertEqual(detail?.parents.count, 1)
    }

    @MainActor
    func testCommitDetailEmptyBodyAndMergeHasTwoParents() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feat"], in: url)
        try TestHelpers.write("f\n", to: url, "f.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "feat commit"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try TestHelpers.write("m\n", to: url, "m.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "master commit"], in: url)
        _ = try await git.run(["merge", "-q", "--no-ff", "-m", "merge feat", "feat"], in: url)
        let hash = (try await git.run(["rev-parse", "HEAD"], in: url)).trimmingCharacters(in: .whitespacesAndNewlines)

        let detail = await store.commitDetail(hash)
        XCTAssertEqual(detail?.subject, "merge feat")
        XCTAssertEqual(detail?.body, "")
        XCTAssertEqual(detail?.parents.count, 2)
        XCTAssertEqual(detail?.parentsShort.count, 2)

        // Diffing against each parent gives different results.
        guard let parents = detail?.parents, parents.count == 2 else { return XCTFail("expected two parents") }
        let firstParentDiff = await store.commitDiff(hash, parent: 1)
        let secondParentDiff = await store.commitDiff(hash, parent: 2)
        XCTAssertNotEqual(firstParentDiff.map(\.path), secondParentDiff.map(\.path))
        // Parent 1 is "master commit" (has m.txt already) — diffing against it shows only what the
        // merge brought in from the other side: f.txt. Parent 2 is "feat commit" (has f.txt
        // already) — diffing against it shows m.txt instead.
        XCTAssertEqual(firstParentDiff.map(\.path), ["f.txt"])
        XCTAssertEqual(secondParentDiff.map(\.path), ["m.txt"])
    }

    // MARK: - File history (T2)

    @MainActor
    func testFileHistoryFollowsRename() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        // Content distinct from the README.md `TestHelpers.makeTempRepo` already committed —
        // matching content would make git's rename-similarity heuristic treat a.txt as a rename of
        // README.md, pulling an unrelated commit into this file's history.
        try TestHelpers.write("alpha one\n", to: url, "a.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add a"))
        try TestHelpers.write("alpha one\nalpha two\n", to: url, "a.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "modify a"))
        let git = GitRunner()
        _ = try await git.run(["mv", "a.txt", "b.txt"], in: url)
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "rename a to b"))
        try TestHelpers.write("alpha one\nalpha two\nalpha three\n", to: url, "b.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "modify b"))

        let entries = await store.fileHistory(path: "b.txt")
        XCTAssertEqual(entries.map(\.commit.subject), ["modify b", "rename a to b", "modify a", "add a"])
        // Every entry's path is the file's name *at that commit* — old name before the rename,
        // new name at and after it.
        XCTAssertEqual(entries.map(\.path), ["b.txt", "b.txt", "a.txt", "a.txt"])
        XCTAssertEqual(entries.map(\.kind), [.modified, .renamed, .modified, .added])

        // The commit diff for an older (pre-rename) entry, using its own path, is exactly that
        // commit's change to the file.
        let oldEntry = entries.first { $0.commit.subject == "modify a" }!
        let files = await store.commitDiff(oldEntry.commit.hash)
        XCTAssertEqual(files.map(\.path), [oldEntry.path])
    }

    @MainActor
    func testFileHistoryWithoutRename() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("1\n", to: url, "plain.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add plain"))
        try TestHelpers.write("1\n2\n", to: url, "plain.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "modify plain"))

        let entries = await store.fileHistory(path: "plain.txt")
        XCTAssertEqual(entries.map(\.commit.subject), ["modify plain", "add plain"])
        XCTAssertEqual(entries.map(\.path), ["plain.txt", "plain.txt"])
        XCTAssertEqual(entries.map(\.kind), [.modified, .added])
    }

    @MainActor
    func testFileHistoryPaging() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        for i in 1...5 {
            try TestHelpers.write("\(i)\n", to: url, "f.txt")
            await store.stageAll()
            _ = await store.commit(CommitMessage(title: "commit \(i)"))
        }
        let page1 = await store.fileHistory(path: "f.txt", limit: 3, skip: 0)
        XCTAssertEqual(page1.count, 3)
        XCTAssertEqual(page1.map(\.commit.subject), ["commit 5", "commit 4", "commit 3"])
        let page2 = await store.fileHistory(path: "f.txt", limit: 3, skip: 3)
        XCTAssertEqual(page2.map(\.commit.subject), ["commit 2", "commit 1"])
    }

    // MARK: - Restore a file version (T2)

    @MainActor
    func testRestoreThisVersion() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("v1\n", to: url, "f.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "v1"))
        let v1Hash = await store.history().first!.hash
        try TestHelpers.write("v2\n", to: url, "f.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "v2"))

        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8), "v2\n")
        let ok = await store.restoreFile("f.txt", from: v1Hash)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8), "v1\n")
    }

    @MainActor
    func testRestoreVersionBeforeCommitEqualsParent() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("v1\n", to: url, "f.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "v1"))
        try TestHelpers.write("v2\n", to: url, "f.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "v2"))
        let v2Hash = await store.history().first!.hash

        let ok = await store.restoreFile("f.txt", from: "\(v2Hash)^")
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8), "v1\n")
    }

    /// Real, surprising git behavior (see `RepositoryStore.restoreFile`'s doc comment): restoring a
    /// currently-tracked path from a commit where it didn't exist yet is not an error — it silently
    /// *deletes* the working-tree file. `fileExists(path:at:)` is what the UI checks first to avoid
    /// ever hitting this.
    @MainActor
    func testRestoreFileThatDidNotExistAtSourceDeletesInsteadOfErroring() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let git = GitRunner()
        let rootHash = (try await git.run(["rev-parse", "HEAD"], in: url)).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestHelpers.write("v1\n", to: url, "new.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add new.txt"))

        let existedAtRoot = await store.fileExists("new.txt", at: rootHash)
        XCTAssertFalse(existedAtRoot)
        // Raw git behaviour, which `restoreFile` refuses (see RestoreFileGuardTests).
        let ok = (try? await git.run(["restore", "--source=\(rootHash)", "--worktree", "--", "new.txt"], in: url)) != nil
        XCTAssertTrue(ok) // exits 0 — no error to surface
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("new.txt").path))
    }

    /// The other real case: a path git has never heard of at all is a genuine, surfaced error.
    @MainActor
    func testRestoreCompletelyUnknownPathErrors() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let hash = await store.history().first!.hash
        let ok = await store.restoreFile("never-existed.txt", from: hash)
        XCTAssertFalse(ok)
        XCTAssertTrue((store.lastError?.stderr ?? "").localizedCaseInsensitiveContains("does not exist"))
    }

    /// `fileExists` returns false both for a root commit's parent ref (no such ref) and for a real
    /// commit where the file genuinely wasn't present yet — the same "disable, don't error" signal
    /// `CommitDiffView`/`HistoryView` use for "Restore Version Before This Commit".
    @MainActor
    func testFileExistsAtCommit() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let rootHash = await store.history().first!.hash
        try TestHelpers.write("v1\n", to: url, "f.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add f"))
        let addHash = await store.history().first!.hash

        let readmeAtRoot = await store.fileExists("README.md", at: rootHash)
        let fAtRoot = await store.fileExists("f.txt", at: rootHash)
        let fBeforeRoot = await store.fileExists("f.txt", at: "\(rootHash)^") // root has no parent
        let fAtAdd = await store.fileExists("f.txt", at: addHash)
        XCTAssertTrue(readmeAtRoot)
        XCTAssertFalse(fAtRoot)
        XCTAssertFalse(fBeforeRoot)
        XCTAssertTrue(fAtAdd)
    }

    // MARK: - Per-commit file statuses (T2)

    @MainActor
    func testCommitFileStatuses() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        try TestHelpers.write("v1\n", to: url, "added.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "add"))
        let addHash = await store.history().first!.hash

        try TestHelpers.write("v1\nv2\n", to: url, "added.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "modify"))
        let modifyHash = await store.history().first!.hash

        let addStatuses = await store.commitFileStatuses(addHash)
        XCTAssertEqual(addStatuses["added.txt"], .added)
        let modifyStatuses = await store.commitFileStatuses(modifyHash)
        XCTAssertEqual(modifyStatuses["added.txt"], .modified)
    }
}

// MARK: - RestoreFileConfirmation (pure)

final class RestoreFileConfirmationTests: XCTestCase {
    func testDetectsUncommittedChangesToThePath() {
        let changes = [FileChange(path: "a.txt", status: .modified, area: .unstaged)]
        XCTAssertTrue(RestoreFileConfirmation.hasUncommittedChanges(path: "a.txt", in: changes))
        XCTAssertFalse(RestoreFileConfirmation.hasUncommittedChanges(path: "b.txt", in: changes))
    }

    func testNoChangesMeansNothingToLose() {
        XCTAssertFalse(RestoreFileConfirmation.hasUncommittedChanges(path: "a.txt", in: []))
    }
}

final class RestoreFileGuardTests: XCTestCase {
    /// `git restore --source=<commit>` silently deletes a tracked file absent at that commit.
    /// `restoreFile` must refuse that.
    @MainActor
    func testRestoreRefusesToDeleteFileAbsentAtSource() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let root = try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestHelpers.write("new\n", to: url, "added.txt")
        _ = try await git.run(["add", "added.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "add"], in: url)

        let store = RepositoryStore(url: url)
        let refused = await store.restoreFile("added.txt", from: root)
        XCTAssertFalse(refused)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("added.txt").path))
    }
}

/// `RepositoryStore.blame(path:)` against real git in a temp repo — two authors, one commit each,
/// plus an uncommitted edit. `BlamePorcelainParserTests` pins down the porcelain format itself;
/// this is the end-to-end path (spawn git, parse off the master actor, cap).
final class RepositoryStoreBlameTests: XCTestCase {
    @MainActor
    func testBlameTwoAuthorsPlusUncommittedEdit() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["config", "user.email", "alice@example.com"], in: url)
        _ = try await git.run(["config", "user.name", "Alice"], in: url)
        try TestHelpers.write("line one\nline two\nline three\n", to: url, "f.txt")
        _ = try await git.run(["add", "f.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "alice: initial"], in: url)

        _ = try await git.run(["config", "user.email", "bob@example.com"], in: url)
        _ = try await git.run(["config", "user.name", "Bob"], in: url)
        try TestHelpers.write("line one\nline two changed\nline three\n", to: url, "f.txt")
        _ = try await git.run(["add", "f.txt"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "bob: change line two"], in: url)

        // Uncommitted edit: an appended fourth line, never staged or committed.
        try TestHelpers.write("line one\nline two changed\nline three\nline four uncommitted\n", to: url, "f.txt")

        let store = RepositoryStore(url: url)
        let result = await store.blame(path: "f.txt")
        let blame = try XCTUnwrap(result)
        XCTAssertEqual(blame.lines.count, 4)
        XCTAssertFalse(blame.truncated)

        XCTAssertEqual(blame.lines[0].author, "Alice")
        XCTAssertEqual(blame.lines[0].summary, "alice: initial")
        XCTAssertFalse(blame.lines[0].isUncommitted)

        XCTAssertEqual(blame.lines[1].author, "Bob")
        XCTAssertEqual(blame.lines[1].summary, "bob: change line two")

        XCTAssertEqual(blame.lines[2].author, "Alice")

        XCTAssertTrue(blame.lines[3].isUncommitted)
        XCTAssertEqual(blame.lines[3].text, "line four uncommitted")
    }

    @MainActor
    func testBlameOnMissingFileReturnsNil() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let result = await store.blame(path: "does-not-exist.txt")
        XCTAssertNil(result)
    }
}
