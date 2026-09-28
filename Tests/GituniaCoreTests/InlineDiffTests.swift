import XCTest
@testable import GituniaCore

final class InlineDiffTests: XCTestCase {
    func testSingleTokenDifferenceHighlightsOnlyThatToken() {
        let removed = "let x = foo(1, 2)"
        let added = "let x = bar(1, 2)"
        let result = InlineDiff.wordRanges(removed: removed, added: added)
        XCTAssertFalse(result.didFallBack)
        XCTAssertEqual(result.removed.map { String(removed[$0]) }, ["foo"])
        XCTAssertEqual(result.added.map { String(added[$0]) }, ["bar"])
    }

    func testCompletelyRewrittenLineFallsBackToFullRange() {
        let removed = "import Foundation"
        let added = "print(42)"
        let result = InlineDiff.wordRanges(removed: removed, added: added)
        XCTAssertTrue(result.didFallBack)
        XCTAssertEqual(result.removed, [removed.startIndex..<removed.endIndex])
        XCTAssertEqual(result.added, [added.startIndex..<added.endIndex])
    }

    func testSeparatedDifferencesProduceTwoRanges() {
        let removed = "return oldName + oldSuffix"
        let added = "return newName + newSuffix"
        let result = InlineDiff.wordRanges(removed: removed, added: added)
        XCTAssertFalse(result.didFallBack)
        // "oldName" and "oldSuffix" differ but are separated by unchanged " + ", so they stay
        // two ranges rather than merging.
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(result.removed.map { String(removed[$0]) }, ["oldName", "oldSuffix"])
        XCTAssertEqual(result.added.map { String(added[$0]) }, ["newName", "newSuffix"])
    }

    func testAdjacentDifferingTokensMergeIntoOneRange() {
        let removed = "return foo,"
        let added = "return bar;"
        let result = InlineDiff.wordRanges(removed: removed, added: added)
        XCTAssertFalse(result.didFallBack)
        // "foo" and "," are two adjacent tokens that both differ; they must merge into one range
        // rather than being reported as two separate highlights.
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.removed.map { String(removed[$0]) }, ["foo,"])
        XCTAssertEqual(result.added.map { String(added[$0]) }, ["bar;"])
    }

    func testPathologicalLineAboveTokenCapReturnsFullRangesQuickly() {
        // Well past the token cap; a naive O(n*m) LCS over this many tokens would hang.
        let removed = Array(repeating: "identifier123 ", count: 3000).joined()
        let added = Array(repeating: "identifier456 ", count: 3000).joined()
        let start = Date()
        let result = InlineDiff.wordRanges(removed: removed, added: added)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertTrue(result.didFallBack)
        XCTAssertEqual(result.removed, [removed.startIndex..<removed.endIndex])
        XCTAssertEqual(result.added, [added.startIndex..<added.endIndex])
    }

    // MARK: - pairs(in:)

    private func line(_ kind: DiffLine.Kind, _ text: String) -> DiffLine {
        DiffLine(kind: kind, text: text, oldNumber: nil, newNumber: nil)
    }

    func testCleanTwoByTwoRunPairsIndexByIndex() {
        let lines = [
            line(.removed, "r0"), line(.removed, "r1"),
            line(.added, "a0"), line(.added, "a1"),
        ]
        let pairs = InlineDiff.pairs(in: lines)
        XCTAssertEqual(pairs, [
            InlineDiff.LinePair(removedIndex: 0, addedIndex: 2),
            InlineDiff.LinePair(removedIndex: 1, addedIndex: 3),
        ])
    }

    func testUnequalRunLengthsPairOnlyTheOverlap() {
        let lines = [
            line(.removed, "r0"), line(.removed, "r1"), line(.removed, "r2"),
            line(.added, "a0"),
        ]
        let pairs = InlineDiff.pairs(in: lines)
        XCTAssertEqual(pairs, [InlineDiff.LinePair(removedIndex: 0, addedIndex: 3)])
    }
}
