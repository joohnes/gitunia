import XCTest
@testable import GituniaCore

final class HistoryFilterTests: XCTestCase {
    func testParse() {
        let cases: [(query: String, words: [String], author: String?, path: String?, gitArgs: [String]?)] = [
            ("\"fix the bug\"", ["fix the bug"], nil, nil, ["--grep=fix the bug", "-i"]),
            ("author:\"Jane Doe\"", [], "Jane Doe", nil, nil),
            ("fix author:jane path:src/foo.swift", ["fix"], "jane", "src/foo.swift",
             ["--grep=fix", "-i", "--author=jane", "-i", "--", "src/foo.swift"]),
            ("foo:bar", ["foo:bar"], nil, nil, nil),
        ]
        for c in cases {
            let f = HistoryFilter.parse(c.query)
            XCTAssertEqual(f.words, c.words, c.query)
            XCTAssertEqual(f.author, c.author, c.query)
            XCTAssertEqual(f.path, c.path, c.query)
            if let args = c.gitArgs { XCTAssertEqual(f.gitArgs, args, c.query) }
        }
    }

    func testInvalidSinceFlaggedNotSentToGit() {
        let f = HistoryFilter.parse("since:notarealdate")
        XCTAssertEqual(f.invalidDateField?.label, "since")
        // An invalid date is left out of the git args entirely — validated separately by the view.
        XCTAssertEqual(f.gitArgs, [])
    }

    func testValidDateForms() {
        for valid in ["2026-09-01", "2 weeks ago", "2.weeks", "2.weeks.ago", "now"] {
            XCTAssertTrue(HistoryFilter.isValidDate(valid), valid)
        }
        for invalid in ["notarealdate", ""] {
            XCTAssertFalse(HistoryFilter.isValidDate(invalid), invalid)
        }
    }
}
