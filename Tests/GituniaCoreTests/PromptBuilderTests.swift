import XCTest
@testable import GituniaCore

final class PromptBuilderTests: XCTestCase {
    func testShortDiffIsKeptWhole() {
        let p = PromptBuilder.build(stat: " a.txt | 1 +", diff: "+hello", limit: 100)
        XCTAssertTrue(p.contains("+hello"))
        XCTAssertTrue(p.contains(" a.txt | 1 +"))
        XCTAssertFalse(p.contains("[diff truncated]"))
        XCTAssertTrue(p.contains("Conventional Commits"))
        XCTAssertTrue(p.contains("\"title\""))
    }

    func testLongDiffIsTruncatedWithMarker() {
        let diff = String(repeating: "x", count: 500)
        let p = PromptBuilder.build(stat: "", diff: diff, limit: 100)
        XCTAssertTrue(p.contains("[diff truncated]"))
        XCTAssertFalse(p.contains(String(repeating: "x", count: 101)))
        XCTAssertTrue(p.contains(String(repeating: "x", count: 100)))
    }
}
