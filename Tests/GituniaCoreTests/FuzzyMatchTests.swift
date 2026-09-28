import XCTest
@testable import GituniaCore

final class FuzzyMatchTests: XCTestCase {
    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatch.score("xyz", "gitunia"))
        XCTAssertNil(FuzzyMatch.score("gitz", "gitunia"))
    }

    func testRankDropsNonMatchesAndSortsDescending() {
        let items = ["gitunia", "hello", "tig"]
        let ranked = FuzzyMatch.rank(items, query: "git", key: { $0 })
        XCTAssertEqual(ranked, ["gitunia"])
    }

    func testRankStableForEqualScores() {
        // Same string repeated scores identically; original relative order must be kept.
        struct Item { let tag: Int; let name: String }
        let items = [Item(tag: 1, name: "abc"), Item(tag: 2, name: "abc"), Item(tag: 3, name: "abc")]
        let ranked = FuzzyMatch.rank(items, query: "abc", key: { $0.name })
        XCTAssertEqual(ranked.map(\.tag), [1, 2, 3])
    }
}
