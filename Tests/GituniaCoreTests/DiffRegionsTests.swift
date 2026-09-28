import XCTest
@testable import GituniaCore

final class DiffRegionsTests: XCTestCase {
    private func l(_ k: DiffLine.Kind, _ t: String = "x") -> DiffLine { DiffLine(kind: k, text: t, oldNumber: nil, newNumber: nil) }

    func testNoChanges() {
        XCTAssertEqual(DiffRegions.changedRegions(in: [l(.context), l(.context)]), [])
    }

    func testSingleRegionSurroundedByContext() {
        let lines = [l(.context), l(.removed), l(.added), l(.context)]
        XCTAssertEqual(DiffRegions.changedRegions(in: lines), [1..<3])
    }

    func testMultipleRegionsSeparatedByContext() {
        let lines = [l(.added), l(.context), l(.context), l(.removed), l(.removed), l(.context), l(.added)]
        XCTAssertEqual(DiffRegions.changedRegions(in: lines), [0..<1, 3..<5, 6..<7])
    }

    func testRegionAtEndWithNoTrailingContext() {
        let lines = [l(.context), l(.added), l(.added)]
        XCTAssertEqual(DiffRegions.changedRegions(in: lines), [1..<3])
    }

    func testEmptyInput() {
        XCTAssertEqual(DiffRegions.changedRegions(in: []), [])
    }
}
