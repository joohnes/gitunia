import XCTest
@testable import GituniaCore

final class HistoryFilterTests: XCTestCase {
    func testEmpty() {
        let f = HistoryFilter.parse("")
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.gitArgs, [])
    }

    func testPlainWords() {
        let f = HistoryFilter.parse("fix bug")
        XCTAssertEqual(f.words, ["fix", "bug"])
        XCTAssertEqual(f.gitArgs, ["--all-match", "--grep=fix", "-i", "--grep=bug", "-i"])
    }

    func testSingleWordNoAllMatch() {
        let f = HistoryFilter.parse("fix")
        XCTAssertEqual(f.gitArgs, ["--grep=fix", "-i"])
    }

    func testQuotedPhrase() {
        let f = HistoryFilter.parse("\"fix the bug\"")
        XCTAssertEqual(f.words, ["fix the bug"])
        XCTAssertEqual(f.gitArgs, ["--grep=fix the bug", "-i"])
    }

    func testAuthorToken() {
        let f = HistoryFilter.parse("author:jane")
        XCTAssertEqual(f.author, "jane")
        XCTAssertEqual(f.gitArgs, ["--author=jane", "-i"])
    }

    func testAuthorTokenQuoted() {
        let f = HistoryFilter.parse("author:\"Jane Doe\"")
        XCTAssertEqual(f.author, "Jane Doe")
    }

    func testPathToken() {
        let f = HistoryFilter.parse("path:src/foo.swift")
        XCTAssertEqual(f.path, "src/foo.swift")
        XCTAssertEqual(f.gitArgs, ["--", "src/foo.swift"])
    }

    func testSinceUntilTokens() {
        let f = HistoryFilter.parse("since:2026-09-01 until:2026-09-20")
        XCTAssertEqual(f.since, "2026-09-01")
        XCTAssertEqual(f.until, "2026-09-20")
        XCTAssertEqual(f.gitArgs, ["--since=2026-09-01", "--until=2026-09-20"])
    }

    func testSinceYesterday() {
        let f = HistoryFilter.parse("since:yesterday")
        XCTAssertTrue(HistoryFilter.isValidDate("yesterday"))
        XCTAssertEqual(f.gitArgs, ["--since=yesterday"])
    }

    func testMixedTokens() {
        let f = HistoryFilter.parse("fix author:jane path:src/foo.swift")
        XCTAssertEqual(f.words, ["fix"])
        XCTAssertEqual(f.author, "jane")
        XCTAssertEqual(f.path, "src/foo.swift")
        XCTAssertEqual(f.gitArgs, ["--grep=fix", "-i", "--author=jane", "-i", "--", "src/foo.swift"])
    }

    func testUnknownPrefixIsFreeText() {
        let f = HistoryFilter.parse("foo:bar")
        XCTAssertEqual(f.words, ["foo:bar"])
        XCTAssertNil(f.author)
    }

    func testInvalidSinceFlaggedNotSentToGit() {
        let f = HistoryFilter.parse("since:notarealdate")
        XCTAssertNotNil(f.invalidDateField)
        XCTAssertEqual(f.invalidDateField?.label, "since")
        // An invalid date is left out of the git args entirely — validated separately by the view.
        XCTAssertEqual(f.gitArgs, [])
    }

    func testValidDateForms() {
        XCTAssertTrue(HistoryFilter.isValidDate("2026-09-01"))
        XCTAssertTrue(HistoryFilter.isValidDate("2 weeks ago"))
        XCTAssertTrue(HistoryFilter.isValidDate("2.weeks"))
        XCTAssertTrue(HistoryFilter.isValidDate("2.weeks.ago"))
        XCTAssertTrue(HistoryFilter.isValidDate("now"))
        XCTAssertFalse(HistoryFilter.isValidDate("notarealdate"))
        XCTAssertFalse(HistoryFilter.isValidDate(""))
    }
}
