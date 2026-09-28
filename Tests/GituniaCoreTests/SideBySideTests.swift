import XCTest
@testable import GituniaCore

final class SideBySideTests: XCTestCase {
    private func l(_ k: DiffLine.Kind, _ t: String) -> DiffLine { DiffLine(kind: k, text: t, oldNumber: nil, newNumber: nil) }

    func testPairsRemovedWithAddedAndKeepsContext() {
        let hunk = Hunk(header: "@@", lines: [
            l(.context, "a"), l(.removed, "b"), l(.removed, "c"), l(.added, "B"), l(.context, "d"), l(.added, "e"),
        ])
        let rows = SideBySide.rows(for: hunk)
        XCTAssertEqual(rows.map { ($0.left?.text ?? "·") + "|" + ($0.right?.text ?? "·") },
                       ["a|a", "b|B", "c|·", "d|d", "·|e"])
    }
}
