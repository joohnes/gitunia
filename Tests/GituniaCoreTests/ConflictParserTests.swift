import XCTest
@testable import GituniaCore

final class ConflictParserTests: XCTestCase {
    func testFileWithNoMarkersIsASingleContextSegment() {
        let text = "line1\nline2\nline3\n"
        let segments = ConflictParser.parse(text)
        XCTAssertEqual(segments, [.context(lines: ["line1", "line2", "line3"])])
    }

    func testEmptyFileHasNoSegments() {
        XCTAssertEqual(ConflictParser.parse(""), [])
    }

    func testSingleConflictBlockSplitsIntoOursAndTheirs() {
        let text = """
        before
        <<<<<<< HEAD
        mine
        =======
        theirs
        >>>>>>> feature
        after
        """
        let segments = ConflictParser.parse(text)
        XCTAssertEqual(segments, [
            .context(lines: ["before"]),
            .conflict(ours: ConflictSide(label: "HEAD", lines: ["mine"]),
                      theirs: ConflictSide(label: "feature", lines: ["theirs"])),
            .context(lines: ["after"]),
        ])
    }

    func testMultipleConflictBlocksInOneFile() {
        let text = """
        a
        <<<<<<< HEAD
        one-mine
        =======
        one-theirs
        >>>>>>> branch
        b
        <<<<<<< HEAD
        two-mine
        =======
        two-theirs
        >>>>>>> branch
        c
        """
        let segments = ConflictParser.parse(text)
        XCTAssertEqual(segments.count, 5)
        guard case .conflict(let ours1, let theirs1) = segments[1],
              case .conflict(let ours2, let theirs2) = segments[3] else {
            return XCTFail("expected conflict segments at indices 1 and 3")
        }
        XCTAssertEqual(ours1.lines, ["one-mine"])
        XCTAssertEqual(theirs1.lines, ["one-theirs"])
        XCTAssertEqual(ours2.lines, ["two-mine"])
        XCTAssertEqual(theirs2.lines, ["two-theirs"])
    }

    func testConflictBlockWithMultipleLinesPerSide() {
        let text = """
        <<<<<<< HEAD
        mine1
        mine2
        =======
        theirs1
        theirs2
        theirs3
        >>>>>>> feature
        """
        let segments = ConflictParser.parse(text)
        XCTAssertEqual(segments, [
            .conflict(ours: ConflictSide(label: "HEAD", lines: ["mine1", "mine2"]),
                      theirs: ConflictSide(label: "feature", lines: ["theirs1", "theirs2", "theirs3"])),
        ])
    }

    // MARK: - M2: merge.conflictStyle diff3/zdiff3 real conflicts

    /// Produces a real conflicted file's contents by actually merging two branches under the
    /// given `merge.conflictStyle`, so the marker text asserted against below is real git output,
    /// not a hand-written fixture.
    private func makeRealConflict(conflictStyle: String) async throws -> String {
        let repo = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        try TestHelpers.write("line1\nline2\nline3\n", to: repo, "f.txt")
        _ = try await git.run(["add", "f.txt"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "base"], in: repo)
        _ = try await git.run(["config", "merge.conflictStyle", conflictStyle], in: repo)
        _ = try await git.run(["checkout", "-q", "-b", "b1"], in: repo)
        try TestHelpers.write("line1\nline2-B1\nline3\n", to: repo, "f.txt")
        _ = try await git.run(["commit", "-q", "-am", "b1"], in: repo)
        _ = try await git.run(["checkout", "-q", "master"], in: repo)
        try TestHelpers.write("line1\nline2-MAIN\nline3\n", to: repo, "f.txt")
        _ = try await git.run(["commit", "-q", "-am", "master"], in: repo)
        _ = try? await git.run(["merge", "b1"], in: repo, allowedExitCodes: [0, 1])
        return try String(contentsOf: repo.appendingPathComponent("f.txt"), encoding: .utf8)
    }

    /// Real conflict under `merge.conflictStyle=diff3` — verified file contents:
    /// ```
    /// line1
    /// <<<<<<< HEAD
    /// line2-MAIN
    /// ||||||| <base-hash>
    /// line2
    /// =======
    /// line2-B1
    /// >>>>>>> b1
    /// line3
    /// ```
    /// The base ("line2" plus the "||||||| ..." marker) must never end up in `ours`.
    func testDiff3BaseSectionExcludedFromOurs() async throws {
        let text = try await makeRealConflict(conflictStyle: "diff3")
        XCTAssertTrue(text.contains("|||||||"), "sanity: real git actually emitted a diff3 base section")
        let segments = ConflictParser.parse(text)
        let conflicts: [(ours: ConflictSide, theirs: ConflictSide)] = segments.compactMap {
            if case .conflict(let ours, let theirs) = $0 { return (ours, theirs) } else { return nil }
        }
        guard let (ours, theirs) = conflicts.first else {
            return XCTFail("expected a conflict segment")
        }
        XCTAssertEqual(ours.lines, ["line2-MAIN"])
        XCTAssertEqual(theirs.lines, ["line2-B1"])
        XCTAssertFalse(ours.lines.contains("line2"))
        XCTAssertFalse(ours.lines.contains { $0.hasPrefix("|||||||") })
    }

    /// Same real-conflict setup under `merge.conflictStyle=zdiff3`.
    func testZdiff3BaseSectionExcludedFromOurs() async throws {
        let text = try await makeRealConflict(conflictStyle: "zdiff3")
        XCTAssertTrue(text.contains("|||||||"), "sanity: real git actually emitted a zdiff3 base section")
        let segments = ConflictParser.parse(text)
        let conflicts: [(ours: ConflictSide, theirs: ConflictSide)] = segments.compactMap {
            if case .conflict(let ours, let theirs) = $0 { return (ours, theirs) } else { return nil }
        }
        guard let (ours, theirs) = conflicts.first else {
            return XCTFail("expected a conflict segment")
        }
        XCTAssertEqual(ours.lines, ["line2-MAIN"])
        XCTAssertEqual(theirs.lines, ["line2-B1"])
    }
}
