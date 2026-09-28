import XCTest
@testable import GituniaCore

final class BlamePorcelainParserTests: XCTestCase {
    /// Real `git blame --porcelain` output captured from a temp repo with two authors (one commit
    /// each) plus an uncommitted edit — see `RepositoryStoreBlameTests` for the equivalent
    /// end-to-end test against real git. Reproduced verbatim here (rather than re-run per test) so
    /// the parser's handling of "metadata only on a hash's first appearance" is pinned down
    /// exactly, including the root commit's `boundary` line and the uncommitted line's literal
    /// "Not Committed Yet" author.
    private let sample = """
    2a9367960ecc267b8463aee31efe9f4e6abbfa72 1 1 1
    author Alice A
    author-mail <a@example.com>
    author-time 1790174101
    author-tz +0200
    committer Alice A
    committer-mail <a@example.com>
    committer-time 1790174101
    committer-tz +0200
    summary first commit
    boundary
    filename f.txt
    \tline one
    f3184388248572c0c5006958c5d201ddb7db4b80 2 2 1
    author Bob B
    author-mail <b@example.com>
    author-time 1790174200
    author-tz +0200
    committer Bob B
    committer-mail <b@example.com>
    committer-time 1790174200
    committer-tz +0200
    summary second commit
    previous 2a9367960ecc267b8463aee31efe9f4e6abbfa72 f.txt
    filename f.txt
    \tline two changed
    2a9367960ecc267b8463aee31efe9f4e6abbfa72 3 3 1
    \tline three
    f3184388248572c0c5006958c5d201ddb7db4b80 4 4 1
    \tline four
    0000000000000000000000000000000000000000 5 5 1
    author Not Committed Yet
    author-mail <not.committed.yet>
    author-time 1790174300
    author-tz +0200
    committer Not Committed Yet
    committer-mail <not.committed.yet>
    committer-time 1790174300
    committer-tz +0200
    summary Version of f.txt from f.txt
    previous f3184388248572c0c5006958c5d201ddb7db4b80 f.txt
    filename f.txt
    \tline five uncommitted
    """

    func testParsesFiveLines() {
        let lines = BlamePorcelainParser.parse(sample)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.map(\.lineNumber), [1, 2, 3, 4, 5])
        XCTAssertEqual(lines.map(\.text), ["line one", "line two changed", "line three", "line four", "line five uncommitted"])
    }

    func testCarriesMetadataForwardAcrossRepeatedHash() {
        let lines = BlamePorcelainParser.parse(sample)
        // Line 3 is the hash's *second* appearance in the output — no metadata lines precede its
        // header — yet it must still carry Alice's author/summary from line 1's record.
        let line3 = lines[2]
        XCTAssertEqual(line3.commitHash, "2a9367960ecc267b8463aee31efe9f4e6abbfa72")
        XCTAssertEqual(line3.author, "Alice A")
        XCTAssertEqual(line3.summary, "first commit")
        XCTAssertEqual(line3.filename, "f.txt")

        let line4 = lines[3]
        XCTAssertEqual(line4.commitHash, "f3184388248572c0c5006958c5d201ddb7db4b80")
        XCTAssertEqual(line4.author, "Bob B")
        XCTAssertEqual(line4.summary, "second commit")
    }

    func testUncommittedLineHasAllZeroHashAndIsFlagged() {
        let lines = BlamePorcelainParser.parse(sample)
        let last = lines[4]
        XCTAssertEqual(last.commitHash, BlamePorcelainParser.uncommittedHash)
        XCTAssertTrue(last.isUncommitted)
        XCTAssertEqual(last.author, "Not Committed Yet")
        XCTAssertFalse(lines[0].isUncommitted)
    }

    func testPreservesLeadingWhitespaceAndTabsInContent() {
        let text = "abcdef0123456789abcdef0123456789abcdef01 1 1 1\nauthor A\nauthor-time 1\nsummary s\nfilename f.txt\n\t\t  indented\tcontent\n"
        let lines = BlamePorcelainParser.parse(text)
        XCTAssertEqual(lines.count, 1)
        // Only the one separator tab is stripped — everything after it, including further tabs
        // and spaces, is the file's own content, verbatim.
        XCTAssertEqual(lines[0].text, "\t  indented\tcontent")
    }
}
