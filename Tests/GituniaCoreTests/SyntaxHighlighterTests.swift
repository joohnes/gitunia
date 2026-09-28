import XCTest
@testable import GituniaCore

final class SyntaxHighlighterTests: XCTestCase {
    private func kinds(_ text: String, _ lang: SyntaxLanguage) -> [(SyntaxToken.Kind, String)] {
        SyntaxHighlighter.tokens(in: text, language: lang).map { ($0.kind, String(text[$0.range])) }
    }

    func testIdentifierContainingKeywordIsPlain() {
        let t = kinds("letter = 1", .swift)
        XCTAssertEqual(t.map(\.0), [.plain, .number])
        XCTAssertEqual(t[0].1, "letter = ")
    }

    func testTokensCoverWholeText() {
        let text = "func f() { return \"a\" } // c"
        let toks = SyntaxHighlighter.tokens(in: text, language: .swift)
        XCTAssertEqual(toks.first?.range.lowerBound, text.startIndex)
        XCTAssertEqual(toks.last?.range.upperBound, text.endIndex)
        for (a, b) in zip(toks, toks.dropFirst()) { XCTAssertEqual(a.range.upperBound, b.range.lowerBound) }
    }
}
