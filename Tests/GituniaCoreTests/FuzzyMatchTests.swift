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

    /// `rank` skips scoring for an empty query and pre-rejects ASCII non-matches; both must leave
    /// results exactly what scoring each candidate with `score` gives.
    func testRankMatchesPerCandidateScore() {
        let items = ["origin/Main", "feature/FooBar", "Ünïcode-bränch", "e\u{301}cole", "release_1.2", "zzz", ""]
        XCTAssertEqual(FuzzyMatch.rank(items, query: "", key: { $0 }), items)
        for query in ["M", "fb", "ün", "e\u{301}", "rel12", "zq"] {
            let expected = items.enumerated()
                .compactMap { i, s in FuzzyMatch.score(query, s).map { ($0, i, s) } }
                .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
                .map(\.2)
            XCTAssertEqual(FuzzyMatch.rank(items, query: query, key: { $0 }), expected, query)
        }
        XCTAssertNotNil(FuzzyMatch.score("FB", "feature/FooBar"))
        XCTAssertNil(FuzzyMatch.score("zq", "feature/FooBar"))
    }
}
