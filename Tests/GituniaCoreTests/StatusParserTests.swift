import XCTest
@testable import GituniaCore

final class StatusParserTests: XCTestCase {
    func testBranchAndAheadBehind() {
        let r = StatusParser.parse("""
        # branch.oid abc
        # branch.head master
        # branch.upstream origin/master
        # branch.ab +2 -1
        """)
        XCTAssertEqual(r.branch, "master")
        XCTAssertEqual(r.ahead, 2)
        XCTAssertEqual(r.behind, 1)
        XCTAssertTrue(r.changes.isEmpty)
    }

    /// Real git 2.50.1 output: a tracked branch whose remote ref was deleted still prints
    /// `branch.upstream` (just no `branch.ab`) — and `rev-parse @{upstream}` counted it too.
    func testUpstreamWithAndWithoutRemoteRef() {
        XCTAssertEqual(StatusParser.upstream(in: "# branch.oid abc\n# branch.head master\n# branch.upstream origin/master\n# branch.ab +0 -0\n? x"), "origin/master")
        XCTAssertEqual(StatusParser.upstream(in: "# branch.oid abc\n# branch.head gone\n# branch.upstream origin/gone\n"), "origin/gone")
        XCTAssertNil(StatusParser.upstream(in: "# branch.oid abc\n# branch.head master\n1 .M N... 100644 100644 100644 a b f"))
        XCTAssertNil(StatusParser.upstream(in: ""))
    }

    func testDetachedHead() {
        let r = StatusParser.parse("# branch.head (detached)")
        XCTAssertEqual(r.branch, "(detached)")
    }

    func testModifiedInBothAreas() {
        let r = StatusParser.parse("1 MM N... 100644 100644 100644 aaa bbb src/App.swift")
        XCTAssertEqual(r.changes, [
            FileChange(path: "src/App.swift", status: .modified, area: .staged),
            FileChange(path: "src/App.swift", status: .modified, area: .unstaged),
        ])
    }

    func testStagedAddAndUnstagedDelete() {
        let r = StatusParser.parse("""
        1 A. N... 000000 100644 100644 000 111 new.txt
        1 .D N... 100644 100644 000000 222 222 gone.txt
        """)
        XCTAssertEqual(r.changes, [
            FileChange(path: "new.txt", status: .added, area: .staged),
            FileChange(path: "gone.txt", status: .deleted, area: .unstaged),
        ])
    }

    func testRename() {
        let r = StatusParser.parse("2 R. N... 100644 100644 100644 aaa aaa R100 new/name.swift\told/name.swift")
        XCTAssertEqual(r.changes, [
            FileChange(path: "new/name.swift", oldPath: "old/name.swift", status: .renamed, area: .staged),
        ])
    }

    func testUntracked() {
        let r = StatusParser.parse("? notes.md")
        XCTAssertEqual(r.changes, [FileChange(path: "notes.md", status: .untracked, area: .unstaged)])
    }

    func testUnmerged() {
        let r = StatusParser.parse("u UU N... 100644 100644 100644 100644 a b c conflict.txt")
        XCTAssertEqual(r.changes, [FileChange(path: "conflict.txt", status: .conflicted, area: .unstaged)])
    }

    func testMalformedLinesAreSkipped() {
        let r = StatusParser.parse("1 M\n2\n1")
        XCTAssertTrue(r.changes.isEmpty)
    }

    // MARK: - C3: real git output for C-quoted paths (tab, newline, quote, backslash, non-ASCII)

    /// Real `git -c core.quotePath=false status --porcelain=v2` (same flag `GitRunner` always
    /// passes) on a temp repo with five untracked files whose names need C-quoting for everything
    /// but the non-ASCII one — verified directly against real git 2.50 output:
    /// ```
    /// ? café.txt
    /// ? "with\ttab.txt"
    /// ? "with\nnewline.txt"
    /// ? "with\"quote.txt"
    /// ? "with\\backslash.txt"
    /// ```
    func testUntrackedFilesWithSpecialCharactersMatchRealGitByteForByte() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let names = [
            "with\ttab.txt",
            "with\nnewline.txt",
            "with\"quote.txt",
            "with\\backslash.txt",
            "café.txt",
        ]
        for name in names {
            try TestHelpers.write("x\n", to: repo, name)
        }
        let out = try await GitRunner().run(["status", "--porcelain=v2", "-uall", "--branch"], in: repo)
        let r = StatusParser.parse(out)
        XCTAssertEqual(Set(r.changes.map(\.path)), Set(names))
    }

    /// Real git for `git mv orig.txt "with<TAB>tab.txt"`: the porcelain v2 "2" (rename) line's
    /// path is quoted, the old path after the real tab separator is not — verified:
    /// `2 R. N... 100644 100644 100644 <h> <h> R100 "with\ttab.txt"<TAB>orig.txt`.
    func testRenameToQuotedPathMatchesRealGit() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("hello\nworld\n", to: repo, "orig.txt")
        _ = try await GitRunner().run(["add", "orig.txt"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "orig"], in: repo)
        _ = try await GitRunner().run(["mv", "orig.txt", "with\ttab.txt"], in: repo)
        let out = try await GitRunner().run(["status", "--porcelain=v2", "-uall", "--branch"], in: repo)
        let r = StatusParser.parse(out)
        XCTAssertEqual(r.changes, [
            FileChange(path: "with\ttab.txt", oldPath: "orig.txt", status: .renamed, area: .staged),
        ])
    }
}
