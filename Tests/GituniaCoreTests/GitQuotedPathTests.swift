import XCTest
@testable import GituniaCore

/// Unit tests for the decoder against the exact quoted forms git prints (verified against real
/// git 2.x output with `-c core.quotePath=false` in a temp repo — see `StatusParserTests`,
/// `DiffParserTests` and `FileHistoryParserTests` for the end-to-end versions that shell out to
/// git itself).
final class GitQuotedPathTests: XCTestCase {
    func testUnquotedPathIsUnchanged() {
        XCTAssertEqual(GitQuotedPath.decode("plain/path.txt"), "plain/path.txt")
    }

    func testTabEscape() {
        XCTAssertEqual(GitQuotedPath.decode("\"with\\ttab.txt\""), "with\ttab.txt")
    }

    func testNewlineEscape() {
        XCTAssertEqual(GitQuotedPath.decode("\"with\\nnewline.txt\""), "with\nnewline.txt")
    }

    func testQuoteEscape() {
        XCTAssertEqual(GitQuotedPath.decode("\"with\\\"quote.txt\""), "with\"quote.txt")
    }

    func testBackslashEscape() {
        XCTAssertEqual(GitQuotedPath.decode("\"with\\\\backslash.txt\""), "with\\backslash.txt")
    }

    func testOctalEscapeDecodesUTF8Bytes() {
        // "café.txt" with core.quotePath left at its default (true) would print é as \303\251.
        XCTAssertEqual(GitQuotedPath.decode("\"caf\\303\\251.txt\""), "café.txt")
    }

    func testUnquotedStringNeverDecoded() {
        // A path that merely contains a literal backslash-t (not a real tab) but wasn't quoted by
        // git must be left untouched — decoding is gated on the outer "..." wrapper, not content.
        XCTAssertEqual(GitQuotedPath.decode("with\\ttab-not-quoted.txt"), "with\\ttab-not-quoted.txt")
    }
}
