import XCTest
@testable import GituniaCore

/// Unit tests for the decoder against the exact quoted forms git prints (verified against real
/// git 2.x output with `-c core.quotePath=false` in a temp repo — see `StatusParserTests`,
/// `DiffParserTests` and `FileHistoryParserTests` for the end-to-end versions that shell out to
/// git itself).
final class GitQuotedPathTests: XCTestCase {
    func testDecode() {
        let cases: [(input: String, decoded: String)] = [
            ("plain/path.txt", "plain/path.txt"),
            ("\"with\\ttab.txt\"", "with\ttab.txt"),
            ("\"with\\nnewline.txt\"", "with\nnewline.txt"),
            ("\"with\\\"quote.txt\"", "with\"quote.txt"),
            ("\"with\\\\backslash.txt\"", "with\\backslash.txt"),
            // "café.txt" with core.quotePath left at its default (true) would print é as \303\251.
            ("\"caf\\303\\251.txt\"", "café.txt"),
            // Decoding is gated on the outer "..." wrapper, not content: an unquoted literal
            // backslash-t is left untouched.
            ("with\\ttab-not-quoted.txt", "with\\ttab-not-quoted.txt"),
        ]
        for c in cases {
            XCTAssertEqual(GitQuotedPath.decode(c.input), c.decoded, c.input)
        }
    }
}
