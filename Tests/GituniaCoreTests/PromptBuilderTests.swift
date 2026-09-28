import XCTest
@testable import GituniaCore

final class PromptBuilderTests: XCTestCase {
    func testLongDiffIsTruncatedWithMarker() {
        let diff = String(repeating: "x", count: 500)
        let p = PromptBuilder.build(stat: "", diff: diff, limit: 100)
        XCTAssertTrue(p.contains("[diff truncated]"))
        XCTAssertFalse(p.contains(String(repeating: "x", count: 101)))
        XCTAssertTrue(p.contains(String(repeating: "x", count: 100)))
    }
}
