import XCTest
@testable import GituniaCore

final class DiffParserTests: XCTestCase {
    func testTwoHunksWithLineNumbers() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        @@ -10,2 +10,3 @@ func x()
         ten
        +ten and a half
         eleven
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        let f = files[0]
        XCTAssertEqual(f.path, "a.txt")
        XCTAssertFalse(f.isBinary)
        XCTAssertEqual(f.hunks.count, 2)
        XCTAssertEqual(f.hunks[0].header, "@@ -1,3 +1,3 @@")
        XCTAssertEqual(f.hunks[0].lines, [
            DiffLine(kind: .context, text: "one", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .removed, text: "two", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .added, text: "TWO", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .context, text: "three", oldNumber: 3, newNumber: 3),
        ])
        XCTAssertEqual(f.hunks[1].lines[1], DiffLine(kind: .added, text: "ten and a half", oldNumber: nil, newNumber: 11))
        XCTAssertEqual(f.hunks[1].lines[2], DiffLine(kind: .context, text: "eleven", oldNumber: 11, newNumber: 12))
    }

    func testNewFile() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let f = DiffParser.parse(diff)[0]
        XCTAssertEqual(f.path, "new.txt")
        XCTAssertEqual(f.hunks[0].lines.map(\.newNumber), [1, 2])
        XCTAssertEqual(f.hunks[0].lines.map(\.kind), [.added, .added])
    }

    func testDeletedFile() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -bye
        -now
        """
        let f = DiffParser.parse(diff)[0]
        XCTAssertEqual(f.path, "gone.txt")
        XCTAssertEqual(f.hunks[0].lines.map(\.oldNumber), [1, 2])
    }

    func testBinary() {
        let diff = """
        diff --git a/img.png b/img.png
        index 111..222 100644
        Binary files a/img.png and b/img.png differ
        """
        let f = DiffParser.parse(diff)[0]
        XCTAssertTrue(f.isBinary)
        XCTAssertTrue(f.hunks.isEmpty)
    }

    func testNoNewlineMarkerIgnoredAndMultipleFiles() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -a
        +b
        \\ No newline at end of file
        diff --git a/y b/y
        --- a/y
        +++ b/y
        @@ -1 +1 @@
        -c
        +d
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.map(\.path), ["x", "y"])
        XCTAssertEqual(files[0].hunks[0].lines.count, 2)
    }

    func testEmpty() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
    }

    func testNoNewlineMarkerIsNotALine() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -a
        +b
        \\ No newline at end of file
        """
        let f = DiffParser.parse(diff)[0]
        XCTAssertEqual(f.hunks[0].lines.count, 2)
    }

    func testContentLinesStartingWithDashesAreKept() {
        let diff = """
        diff --git a/x.sql b/x.sql
        --- a/x.sql
        +++ b/x.sql
        @@ -1,2 +1,2 @@
        --- drop legacy table
        +++ added
         context
        """
        let f = DiffParser.parse(diff)[0]
        XCTAssertEqual(f.hunks[0].lines.map(\.kind), [.removed, .added, .context])
        XCTAssertEqual(f.hunks[0].lines.map(\.text), ["-- drop legacy table", "++ added", "context"])
        XCTAssertEqual(f.hunks[0].lines[0].oldNumber, 1)
        XCTAssertNil(f.hunks[0].lines[0].newNumber)
        XCTAssertNil(f.hunks[0].lines[1].oldNumber)
        XCTAssertEqual(f.hunks[0].lines[1].newNumber, 1)
        XCTAssertEqual(f.hunks[0].lines[2].oldNumber, 2)
        XCTAssertEqual(f.hunks[0].lines[2].newNumber, 2)
    }

    func testPathWithSpaceAndBSlash() {
        let diff = """
        diff --git a/foo b/bar.txt b/foo b/bar.txt
        --- a/foo b/bar.txt\t
        +++ b/foo b/bar.txt\t
        @@ -1 +1 @@
        -old
        +new
        """
        let f = DiffParser.parse(diff)[0]
        XCTAssertEqual(f.path, "foo b/bar.txt")
    }

    // MARK: - C3: real git output for C-quoted paths

    /// Real `git -c core.quotePath=false diff --cached` (same flags `GitRunner` uses) on new files
    /// named with a tab, a literal quote and a literal backslash — verified byte-for-byte, e.g.:
    /// ```
    /// diff --git "a/with\ttab.txt" "b/with\ttab.txt"
    /// new file mode 100644
    /// --- /dev/null
    /// +++ "b/with\ttab.txt"
    /// ```
    func testQuotedPathsInDiffHeaderMatchRealGitByteForByte() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let names = ["with\ttab.txt", "with\"quote.txt", "with\\backslash.txt"]
        for name in names {
            try TestHelpers.write("x\n", to: repo, name)
        }
        _ = try await GitRunner().run(["add", "-A"], in: repo)
        let out = try await GitRunner().run(["diff", "--cached"], in: repo)
        let files = DiffParser.parse(out)
        XCTAssertEqual(Set(files.map(\.path)), Set(names))
    }

    // MARK: - M1: pathFromDiffHeader for header-only cases (rename/binary/mode-only)

    /// Real `git mv "dir b/file.txt" "dir b/renamed.txt"` then `git diff --cached -M` (100%
    /// similarity, so no ---/+++ lines) — verified:
    /// ```
    /// diff --git a/dir b/file.txt b/dir b/renamed.txt
    /// similarity index 100%
    /// rename from dir b/file.txt
    /// rename to dir b/renamed.txt
    /// ```
    /// The old backwards-substring-search implementation matched the `" b/"` embedded inside the
    /// new path itself and returned "renamed.txt" instead of "dir b/renamed.txt".
    func testPureRenameWithEmbeddedBSlashInPathUsesRenameToLine() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("dir b"), withIntermediateDirectories: true)
        try TestHelpers.write("hello\nworld\n", to: repo, "dir b/file.txt")
        _ = try await GitRunner().run(["add", "dir b/file.txt"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add"], in: repo)
        _ = try await GitRunner().run(["mv", "dir b/file.txt", "dir b/renamed.txt"], in: repo)
        let out = try await GitRunner().run(["diff", "--cached", "-M"], in: repo)
        let files = DiffParser.parse(out)
        XCTAssertEqual(files.map(\.path), ["dir b/renamed.txt"])
    }

    /// Real binary diff of a file in a directory literally named `x b` (mode-only change, so no
    /// ---/+++ and old == new) — verified:
    /// ```
    /// diff --git a/x b/file.bin b/x b/file.bin
    /// old mode 100644
    /// new mode 100755
    /// index a3e5b66..9d45525
    /// Binary files a/x b/file.bin and b/x b/file.bin differ
    /// ```
    func testBinaryFileInDirectoryContainingBSlashUsesMidpointSplit() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let dir = repo.appendingPathComponent("x b")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("file.bin")
        try Data([0x00, 0x01, 0x02]).write(to: file)
        _ = try await GitRunner().run(["add", "x b/file.bin"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add"], in: repo)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: file) // modify content, keep old == new path
        let out = try await GitRunner().run(["diff"], in: repo, allowedExitCodes: [0, 1])
        let files = DiffParser.parse(out)
        XCTAssertEqual(files.map(\.path), ["x b/file.bin"])
        XCTAssertTrue(files[0].isBinary)
    }
}
