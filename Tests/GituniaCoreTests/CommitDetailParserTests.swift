import XCTest
@testable import GituniaCore

final class CommitDetailParserTests: XCTestCase {
    func testParsesAllFields() {
        let us = "\u{1f}", rs = "\u{1e}"
        let text = "hash1\(us)subject line\(us)body line one\nbody line two\(us)Alice\(us)alice@x.com\(us)2026-09-20T10:00:00+02:00\(us)Bob\(us)bob@x.com\(us)2026-09-21T11:00:00+02:00\(us)parentFull1 parentFull2\(us)p1 p2\(rs)\n"
        let detail = CommitDetailParser.parse(text)
        XCTAssertEqual(detail?.hash, "hash1")
        XCTAssertEqual(detail?.subject, "subject line")
        XCTAssertEqual(detail?.body, "body line one\nbody line two")
        XCTAssertEqual(detail?.authorName, "Alice")
        XCTAssertEqual(detail?.authorEmail, "alice@x.com")
        XCTAssertEqual(detail?.committerName, "Bob")
        XCTAssertEqual(detail?.parents, ["parentFull1", "parentFull2"])
        XCTAssertEqual(detail?.parentsShort, ["p1", "p2"])
        XCTAssertTrue(detail?.committerDiffersFromAuthor ?? false)
    }

    func testEmptyBodyAndSingleParent() {
        let us = "\u{1f}", rs = "\u{1e}"
        let text = "h\(us)s\(us)\(us)A\(us)a@x.com\(us)d1\(us)A\(us)a@x.com\(us)d1\(us)p1\(us)p1s\(rs)\n"
        let detail = CommitDetailParser.parse(text)
        XCTAssertEqual(detail?.body, "")
        XCTAssertEqual(detail?.parents, ["p1"])
        XCTAssertFalse(detail?.committerDiffersFromAuthor ?? true)
    }
}
