import XCTest
@testable import GituniaCore

/// Line-level stage / unstage / discard, verified by actually applying the patches in throwaway
/// repos (`git apply --check` first, then the real store operation) and comparing the resulting
/// index / working-tree bytes exactly.
@MainActor
final class LinePatchTests: XCTestCase {
    private let git = GitRunner()
    private let file = "f.txt"

    /// Commits `base`, stages `index` (if given), then leaves `worktree` in the working tree.
    private func makeRepo(base: String, index: String? = nil, worktree: String) async throws -> RepositoryStore {
        let url = try await TestHelpers.makeTempRepo()
        let path = url.appendingPathComponent(file)
        try Data(base.utf8).write(to: path)
        _ = try await git.run(["add", file], in: url)
        _ = try await git.run(["commit", "-q", "-m", "base"], in: url)
        if let index {
            try Data(index.utf8).write(to: path)
            _ = try await git.run(["add", file], in: url)
        }
        try Data(worktree.utf8).write(to: path)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return store
    }

    private func change(_ store: RepositoryStore, _ area: FileChange.Area) throws -> FileChange {
        try XCTUnwrap(store.repo.changes.first { $0.path == file && $0.area == area })
    }

    private func indexContent(_ store: RepositoryStore) async throws -> String {
        String(decoding: try await git.runData(["show", ":\(file)"], in: store.url), as: UTF8.self)
    }

    private func worktreeContent(_ store: RepositoryStore) throws -> String {
        String(decoding: try Data(contentsOf: store.url.appendingPathComponent(file)), as: UTF8.self)
    }

    /// Refs of every line of `kind` whose text is in `texts`.
    private func refs(_ diff: FileDiff, _ kind: DiffLine.Kind, _ texts: String...) -> Set<DiffLineRef> {
        var out = Set<DiffLineRef>()
        for (h, hunk) in diff.hunks.enumerated() {
            for (i, line) in hunk.lines.enumerated() where line.kind == kind && texts.contains(line.text) {
                out.insert(DiffLineRef(hunk: h, line: i))
            }
        }
        XCTAssertEqual(out.count, texts.count, "selection helper matched the wrong number of lines")
        return out
    }

    private enum Op { case stage, unstage, discard }

    /// Loads the diff, `git apply --check`s the patch, then runs the store operation.
    private func run(_ op: Op, _ store: RepositoryStore, context: Int? = nil,
                     select: (FileDiff) -> Set<DiffLineRef>) async throws {
        let c = try change(store, op == .unstage ? .staged : .unstaged)
        let loaded = await store.diff(for: c, context: context)
        let diff = try XCTUnwrap(loaded)
        let selected = select(diff)
        let reverse = op != .stage
        let patch = try XCTUnwrap(PatchBuilder.patch(path: file, hunks: diff.hunks, selected: selected, reverse: reverse))
        let check: [String] = switch op {
        case .stage: ["apply", "--check", "--cached"]
        case .unstage: ["apply", "--check", "--cached", "--reverse"]
        case .discard: ["apply", "--check", "--reverse"]
        }
        _ = try await git.run(check, in: store.url, stdin: patch)
        let ok: Bool = switch op {
        case .stage: await store.stageLines(selected, in: diff, of: c)
        case .unstage: await store.unstageLines(selected, in: diff, of: c)
        case .discard: await store.discardLines(selected, in: diff, of: c)
        }
        XCTAssertTrue(ok, "\(store.lastError?.stderr ?? "")\n\(patch)")
    }

    // MARK: - Stage

    func testStageOneAddedLineInMixedHunk() async throws {
        let wt = "1\nTWO\n3\nnew\n4\n5\n"
        let store = try await makeRepo(base: "1\n2\n3\n4\n5\n", worktree: wt)
        try await run(.stage, store) { self.refs($0, .added, "new") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n2\n3\nnew\n4\n5\n")
        XCTAssertEqual(try worktreeContent(store), wt)
    }

    func testStageOneRemovedLine() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n4\n5\n", worktree: "1\n3\n5\n")
        try await run(.stage, store) { self.refs($0, .removed, "4") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n2\n3\n5\n")
    }

    func testStageOnlyTheAddedHalfOfAReplacedPair() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n", worktree: "1\nTWO\n3\n")
        try await run(.stage, store) { self.refs($0, .added, "TWO") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n2\nTWO\n3\n")
    }

    func testStageOnlyTheRemovedHalfOfAReplacedPair() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n", worktree: "1\nTWO\n3\n")
        try await run(.stage, store) { self.refs($0, .removed, "2") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n3\n")
    }

    /// Two separate hunks (recomputed header offsets) plus a gap inside one hunk.
    func testStageNonContiguousAcrossHunks() async throws {
        let base = (1...20).map { "l\($0)\n" }.joined()
        var wt = (1...20).map { "l\($0)\n" }
        wt.insert(contentsOf: ["a1\n", "a2\n", "a3\n"], at: 1)   // after l1
        wt.removeAll { $0 == "l15\n" || $0 == "l17\n" }
        wt.append("tail\n")
        let store = try await makeRepo(base: base, worktree: wt.joined())
        try await run(.stage, store) { self.refs($0, .added, "a1", "a3", "tail").union(self.refs($0, .removed, "l17")) }
        var expected = (1...20).map { "l\($0)\n" }
        expected.insert(contentsOf: ["a1\n", "a3\n"], at: 1)
        expected.removeAll { $0 == "l17\n" }
        expected.append("tail\n")
        let index = try await indexContent(store)
        XCTAssertEqual(index, expected.joined())
    }

    func testStageFirstAndLastLineOfFile() async throws {
        let store = try await makeRepo(base: "a\nb\nc\n", worktree: "top\ntop2\na\nb\nc\nend\n")
        try await run(.stage, store) { self.refs($0, .added, "top", "end") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "top\na\nb\nc\nend\n")
    }

    /// Whole-file (`-U100000`) diff: one giant hunk, line staging still changes only the selection.
    func testStageInWholeFileMode() async throws {
        let base = (1...30).map { "l\($0)\n" }.joined()
        let wt = base.replacingOccurrences(of: "l3\n", with: "L3\n").replacingOccurrences(of: "l28\n", with: "L28\n")
        let store = try await makeRepo(base: base, worktree: wt)
        try await run(.stage, store, context: 100_000) { self.refs($0, .added, "L28").union(self.refs($0, .removed, "l28")) }
        let index = try await indexContent(store)
        XCTAssertEqual(index, base.replacingOccurrences(of: "l28\n", with: "L28\n"))
    }

    // MARK: - No newline at end of file

    /// Old file ends "b" without newline; worktree appends "c\n". Staging only "+c" must still
    /// give "b" its newline (git's own "-b / \ No newline / +b" split).
    func testStageAppendAfterUnterminatedLastLine() async throws {
        let store = try await makeRepo(base: "a\nb", worktree: "a\nb\nc\n")
        try await run(.stage, store) { self.refs($0, .added, "c") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nb\nc\n")
    }

    func testStageOnlyTheNewlineFix() async throws {
        let store = try await makeRepo(base: "a\nb", worktree: "a\nb\nc\n")
        try await run(.stage, store) { self.refs($0, .added, "b").union(self.refs($0, .removed, "b")) }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nb\n")
    }

    func testStageAddedUnterminatedLastLine() async throws {
        let store = try await makeRepo(base: "a\nb\n", worktree: "a\nB")
        try await run(.stage, store) { self.refs($0, .added, "B") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nb\nB")
    }

    func testStageRemovalBeforeUnterminatedLastLine() async throws {
        let store = try await makeRepo(base: "a\nb\nc", worktree: "a\nc")
        try await run(.stage, store) { self.refs($0, .removed, "b") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nc")
    }

    func testStageRemovingUnterminatedLastLineKeepsReplacementOut() async throws {
        let store = try await makeRepo(base: "a\nb", worktree: "a\nB")
        try await run(.stage, store) { self.refs($0, .removed, "b") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\n")
    }

    /// Whole-hunk staging used to be disabled for marker hunks — it now applies.
    func testStageWholeHunkWithNoNewlineMarker() async throws {
        let store = try await makeRepo(base: "a\nb", worktree: "a\nB")
        let c = try change(store, .unstaged)
        let loaded = await store.diff(for: c)
        let diff = try XCTUnwrap(loaded)
        let ok = await store.stageHunk(diff.hunks[0], of: c)
        XCTAssertTrue(ok, store.lastError?.stderr ?? "")
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nB")
    }

    // MARK: - CRLF

    func testStageLineInCRLFFile() async throws {
        let wt = "a\r\nB\r\nc\r\nd\r\n"
        let store = try await makeRepo(base: "a\r\nb\r\nc\r\n", worktree: wt)
        try await run(.stage, store) { self.refs($0, .added, "d\r") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\r\nb\r\nc\r\nd\r\n")
        XCTAssertEqual(try worktreeContent(store), wt)
    }

    // MARK: - Unstage

    func testUnstageOneAddedLine() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n", index: "1\nx\n2\ny\n3\n", worktree: "1\nx\n2\ny\n3\n")
        try await run(.unstage, store) { self.refs($0, .added, "x") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n2\ny\n3\n")
        XCTAssertEqual(try worktreeContent(store), "1\nx\n2\ny\n3\n")
    }

    func testUnstageOneRemovedLine() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n4\n", index: "1\n4\n", worktree: "1\n4\n")
        try await run(.unstage, store) { self.refs($0, .removed, "3") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n3\n4\n")
    }

    func testUnstageHalvesOfAReplacedPair() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n", index: "1\nTWO\n3\n", worktree: "1\nTWO\n3\n")
        try await run(.unstage, store) { self.refs($0, .added, "TWO") }
        let index1 = try await indexContent(store)
        XCTAssertEqual(index1, "1\n3\n")

        let store2 = try await makeRepo(base: "1\n2\n3\n", index: "1\nTWO\n3\n", worktree: "1\nTWO\n3\n")
        try await run(.unstage, store2) { self.refs($0, .removed, "2") }
        let index2 = try await indexContent(store2)
        XCTAssertEqual(index2, "1\n2\nTWO\n3\n")
    }

    func testUnstageNonContiguousAcrossHunks() async throws {
        let base = (1...20).map { "l\($0)\n" }.joined()
        var staged = (1...20).map { "l\($0)\n" }
        staged.insert(contentsOf: ["a1\n", "a2\n", "a3\n"], at: 1)
        staged.removeAll { $0 == "l15\n" || $0 == "l17\n" }
        staged.append("tail\n")
        let store = try await makeRepo(base: base, index: staged.joined(), worktree: staged.joined())
        try await run(.unstage, store) { self.refs($0, .added, "a2", "tail").union(self.refs($0, .removed, "l15")) }
        var expected = (1...20).map { "l\($0)\n" }
        expected.insert(contentsOf: ["a1\n", "a3\n"], at: 1)
        expected.removeAll { $0 == "l17\n" }
        let index = try await indexContent(store)
        XCTAssertEqual(index, expected.joined())
    }

    func testUnstageAppendAfterUnterminatedLastLine() async throws {
        let store = try await makeRepo(base: "a\nb", index: "a\nb\nc\n", worktree: "a\nb\nc\n")
        try await run(.unstage, store) { self.refs($0, .added, "c") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nb\n")
    }

    func testUnstageUnterminatedAddedLastLine() async throws {
        let store = try await makeRepo(base: "a\nb\n", index: "a\nb\nC", worktree: "a\nb\nC")
        try await run(.unstage, store) { self.refs($0, .added, "C") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\nb\n")
    }

    func testUnstageInCRLFFile() async throws {
        let staged = "a\r\nB\r\nc\r\n"
        let store = try await makeRepo(base: "a\r\nb\r\nc\r\n", index: staged, worktree: staged)
        try await run(.unstage, store) { self.refs($0, .added, "B\r") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "a\r\nc\r\n")
    }

    func testUnstageLinesOfNewlyAddedFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try Data("x\ny\nz\n".utf8).write(to: url.appendingPathComponent(file))
        _ = try await git.run(["add", file], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertTrue(RepositoryStore.supportsLineActions(try change(store, .staged)))
        try await run(.unstage, store) { self.refs($0, .added, "y") }
        let index = try await indexContent(store)
        XCTAssertEqual(index, "x\nz\n")
    }

    // MARK: - Discard

    func testDiscardSelectedLinesOnlyTouchesWorktree() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n4\n", worktree: "1\nTWO\n3\nnew\n4\n")
        try await run(.discard, store) { self.refs($0, .added, "TWO").union(self.refs($0, .removed, "2")) }
        XCTAssertEqual(try worktreeContent(store), "1\n2\n3\nnew\n4\n")
        let index = try await indexContent(store)
        XCTAssertEqual(index, "1\n2\n3\n4\n")
    }

    func testDiscardOnlyRemovedLineRestoresIt() async throws {
        let store = try await makeRepo(base: "1\n2\n3\n", worktree: "1\n3\n")
        try await run(.discard, store) { self.refs($0, .removed, "2") }
        XCTAssertEqual(try worktreeContent(store), "1\n2\n3\n")
    }

    func testDiscardAppendAfterUnterminatedLastLine() async throws {
        let store = try await makeRepo(base: "a\nb", worktree: "a\nb\nc\nd\n")
        try await run(.discard, store) { self.refs($0, .added, "d") }
        XCTAssertEqual(try worktreeContent(store), "a\nb\nc\n")
    }

    func testDiscardRefusesStagedChange() async throws {
        let store = try await makeRepo(base: "1\n", index: "2\n", worktree: "2\n")
        let c = try change(store, .staged)
        let loaded = await store.diff(for: c)
        let diff = try XCTUnwrap(loaded)
        let ok = await store.discardLines([DiffLineRef(hunk: 0, line: 0)], in: diff, of: c)
        XCTAssertFalse(ok)
    }

    // MARK: - Parser

    func testParserFlagsTheLineEachNoNewlineMarkerFollows() {
        let f = DiffParser.parse("""
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
         a
        -b
        \\ No newline at end of file
        +B
        """)[0]
        XCTAssertEqual(f.hunks[0].lines.map(\.noNewline), [false, true, false])
    }

    // MARK: - Pure construction

    func testHeaderRecountAndNilForEmptySelection() {
        let hunk = Hunk(header: "@@ -10,4 +10,4 @@ func", lines: [
            DiffLine(kind: .context, text: "c", oldNumber: 10, newNumber: 10),
            DiffLine(kind: .removed, text: "a", oldNumber: 11, newNumber: nil),
            DiffLine(kind: .removed, text: "b", oldNumber: 12, newNumber: nil),
            DiffLine(kind: .added, text: "A", oldNumber: nil, newNumber: 11),
            DiffLine(kind: .added, text: "B", oldNumber: nil, newNumber: 12),
            DiffLine(kind: .context, text: "d", oldNumber: 13, newNumber: 13),
        ])
        XCTAssertNil(PatchBuilder.patch(path: "p", hunks: [hunk], selected: [], reverse: false))
        XCTAssertNil(PatchBuilder.patch(path: "p", hunks: [hunk], selected: [DiffLineRef(hunk: 0, line: 0)], reverse: false))
        let sel: Set = [DiffLineRef(hunk: 0, line: 1), DiffLineRef(hunk: 0, line: 3)]
        XCTAssertEqual(PatchBuilder.patch(path: "p", hunks: [hunk], selected: sel, reverse: false), """
        diff --git a/p b/p
        --- a/p
        +++ b/p
        @@ -10,4 +10,4 @@
         c
        -a
         b
        +A
         d

        """)
        XCTAssertEqual(PatchBuilder.patch(path: "p", hunks: [hunk], selected: sel, reverse: true), """
        diff --git a/p b/p
        --- a/p
        +++ b/p
        @@ -10,4 +10,4 @@
         c
        -a
        +A
         B
         d

        """)
    }
}
