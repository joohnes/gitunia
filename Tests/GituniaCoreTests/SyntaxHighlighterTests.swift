import XCTest
@testable import GituniaCore

final class SyntaxHighlighterTests: XCTestCase {
    private func kinds(_ text: String, _ lang: SyntaxLanguage) -> [(SyntaxToken.Kind, String)] {
        SyntaxHighlighter.tokens(in: text, language: lang).map { ($0.kind, String(text[$0.range])) }
    }

    func testSwiftLine() {
        let t = kinds(#"let x = "hi" // note 42"#, .swift)
        XCTAssertEqual(t.map(\.0), [.keyword, .plain, .string, .plain, .comment])
        XCTAssertEqual(t.map(\.1), ["let", " x = ", "\"hi\"", " ", "// note 42"])
    }

    func testNumbersAndPythonComment() {
        let t = kinds("return 3.14 # pi", .python)
        XCTAssertEqual(t.map(\.0), [.keyword, .plain, .number, .plain, .comment])
    }

    func testIdentifierContainingKeywordIsPlain() {
        let t = kinds("letter = 1", .swift)
        XCTAssertEqual(t.map(\.0), [.plain, .number])
        XCTAssertEqual(t[0].1, "letter = ")
    }

    func testUnterminatedStringRunsToEnd() {
        let t = kinds(#"x = "oops"#, .javascript)
        XCTAssertEqual(t.last?.0, .string)
        XCTAssertEqual(t.last?.1, "\"oops")
    }

    func testTokensCoverWholeText() {
        let text = "func f() { return \"a\" } // c"
        let toks = SyntaxHighlighter.tokens(in: text, language: .swift)
        XCTAssertEqual(toks.first?.range.lowerBound, text.startIndex)
        XCTAssertEqual(toks.last?.range.upperBound, text.endIndex)
        for (a, b) in zip(toks, toks.dropFirst()) { XCTAssertEqual(a.range.upperBound, b.range.lowerBound) }
    }

    func testOtherLanguageIsPlainOnly() {
        XCTAssertEqual(kinds("let x = 1 // c", .other).map(\.0), [.plain])
    }

    func testApostropheInMarkdownIsNotAString() {
        let t = kinds("don't ship this", .markdown)
        XCTAssertFalse(t.contains { $0.0 == .string })
    }

    func testLanguageFromExtension() {
        XCTAssertEqual(SyntaxLanguage.from(fileExtension: "ts"), .javascript)
        XCTAssertEqual(SyntaxLanguage.from(fileExtension: "PY"), .python)
        XCTAssertEqual(SyntaxLanguage.from(fileExtension: "xyz"), .other)
    }
}
