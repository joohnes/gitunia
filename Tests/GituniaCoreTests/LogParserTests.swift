import XCTest
@testable import GituniaCore

final class LogParserTests: XCTestCase {
    func testParsesRecords() {
        let us = "\u{1f}", rs = "\u{1e}"
        let text = "abc123\(us)abc\(us)Ala\(us)2026-09-22\(us)feat: one\(us)parent1\(rs)\ndef456\(us)def\(us)Bob\(us)2026-09-21\(us)fix: two\(us)parentA parentB\(rs)\nfed789\(us)fed\(us)Ala\(us)2026-09-20\(us)init\(us)\(rs)\n"
        XCTAssertEqual(LogParser.parse(text), [
            CommitInfo(hash: "abc123", shortHash: "abc", author: "Ala", date: "2026-09-22", subject: "feat: one", parentCount: 1),
            CommitInfo(hash: "def456", shortHash: "def", author: "Bob", date: "2026-09-21", subject: "fix: two", parentCount: 2),
            CommitInfo(hash: "fed789", shortHash: "fed", author: "Ala", date: "2026-09-20", subject: "init", parentCount: 0),
        ])
    }
}
