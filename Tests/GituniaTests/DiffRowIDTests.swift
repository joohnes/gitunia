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
}
