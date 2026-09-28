import XCTest
@testable import GituniaCore

final class FuzzyMatchTests: XCTestCase {
    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatch.score("xyz", "gitunia"))
        XCTAssertNil(FuzzyMatch.score("gitz", "gitunia"))
    }

    func testEmptyQueryMatchesEverythingWithEqualScore() {
        XCTAssertEqual(FuzzyMatch.score("", "anything"), 0)
        XCTAssertEqual(FuzzyMatch.score("", ""), 0)
    }

    func testEmptyQueryRankPreservesOriginalOrder() {
        let items = ["zebra", "apple", "mango"]
        XCTAssertEqual(FuzzyMatch.rank(items, query: "", key: { $0 }), items)
    }

    func testCaseInsensitiveSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score("GITU", "gitunia"))
    }

    func testPrefixBeatsMidWord() {
        let prefixScore = FuzzyMatch.score("gitu", "gitunia")!
        let midWordScore = FuzzyMatch.score("gitu", "legitunify")!
        XCTAssertGreaterThan(prefixScore, midWordScore)
    }

    func testConsecutiveBeatsScattered() {
        let consecutive = FuzzyMatch.score("git", "gitunia")!
        let scattered = FuzzyMatch.score("git", "grouping trait")!
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testWordBoundaryBeatsMidWord() {
        let boundary = FuzzyMatch.score("sv", "sidebar_view")!
        let midWord = FuzzyMatch.score("sv", "observedValue")!
        XCTAssertGreaterThan(boundary, midWord)
    }

    func testShortCandidateBeatsLongCandidateForSameQuery() {
        let short = FuzzyMatch.score("sv", "sv")!
        let long = FuzzyMatch.score("sv", "some/very/long/path/to/sidebarview.swift")!
        XCTAssertGreaterThan(short, long)
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
