import XCTest
@testable import Gitunia

/// Regression: inline and split rows once shared an identity string, so flipping Inline/Split
/// let SwiftUI reuse the other branch's row views and a file rendered in the wrong mode.
final class DiffRowIDTests: XCTestCase {
    func testInlineAndSplitRowsNeverShareAnIdentity() {
        for line in 0..<50 {
            let inline = DiffRowID.row(mode: .inline, diffHash: 1234, hunk: 0, line: line)
            let split = DiffRowID.row(mode: .split, diffHash: 1234, hunk: 0, line: line)
            XCTAssertNotEqual(inline, split, "row \(line) shares an id across modes")
        }
    }

    func testInlineAndSplitSectionsNeverShareAnIdentity() {
        let key = "1234-0-2"
        XCTAssertNotEqual(DiffRowID.section(mode: .inline, key: key),
                          DiffRowID.section(mode: .split, key: key))
    }

    func testRowIdentityIsStableForTheSameInputs() {
        XCTAssertEqual(DiffRowID.row(mode: .inline, diffHash: 7, hunk: 1, line: 3),
                       DiffRowID.row(mode: .inline, diffHash: 7, hunk: 1, line: 3))
    }

    func testDifferentDiffsNeverShareRowIdentities() {
        XCTAssertNotEqual(DiffRowID.row(mode: .inline, diffHash: 7, hunk: 0, line: 0),
                          DiffRowID.row(mode: .inline, diffHash: 8, hunk: 0, line: 0))
    }

    /// The expand/collapse key must NOT carry the mode — a section the user expanded should stay
    /// expanded when they switch Inline/Split. Only the ForEach identity is mode-salted.
    func testSectionKeyAndIdentityAreDistinctConcerns() {
        let key = "99-0-1"
        XCTAssertFalse(key.contains("inline"))
        XCTAssertTrue(DiffRowID.section(mode: .inline, key: key).contains(key))
    }
}
