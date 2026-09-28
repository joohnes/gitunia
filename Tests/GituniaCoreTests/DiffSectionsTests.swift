import XCTest
@testable import GituniaCore

final class DiffSectionsTests: XCTestCase {
    private func l(_ k: DiffLine.Kind, _ t: String = "x") -> DiffLine { DiffLine(kind: k, text: t, oldNumber: nil, newNumber: nil) }
    private func context(_ n: Int) -> [DiffLine] { (0..<n).map { _ in l(.context) } }

    private func allLines(_ sections: [DiffSection]) -> [DiffLine] {
        sections.flatMap { section -> [DiffLine] in
            switch section {
            case .changed(let lines): return lines
            case .unchanged(let lines, _): return lines
            }
        }
    }

    func testLongInteriorRunCollapsesWithPaddingBothSides() {
        let lines = [l(.removed)] + context(412) + [l(.added)]
        let sections = DiffSections.sections(for: lines)
        XCTAssertEqual(sections.count, 5) // changed, padding, collapsible, padding, changed
        guard case .changed = sections[0] else { return XCTFail("expected changed") }
        guard case .unchanged(let lead, let leadCollapsible) = sections[1] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(lead.count, 4)
        XCTAssertFalse(leadCollapsible)
        guard case .unchanged(let middle, let middleCollapsible) = sections[2] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(middle.count, 404)
        XCTAssertTrue(middleCollapsible)
        guard case .unchanged(let trail, let trailCollapsible) = sections[3] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(trail.count, 4)
        XCTAssertFalse(trailCollapsible)
        guard case .changed = sections[4] else { return XCTFail("expected changed") }
        XCTAssertEqual(allLines(sections), lines)
    }

    func testRunExactlyAtThresholdDoesNotCollapse() {
        let lines = [l(.removed)] + context(12) + [l(.added)]
        let sections = DiffSections.sections(for: lines, collapseThreshold: 12, padding: 4)
        XCTAssertEqual(sections.count, 3)
        guard case .unchanged(let middle, let collapsible) = sections[1] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(middle.count, 12)
        XCTAssertFalse(collapsible)
        XCTAssertEqual(allLines(sections), lines)
    }

    func testRunJustOverThresholdWithRemainderBelowMinimumStaysWhole() {
        // 13 lines, padding 4 each side -> middle would be 5, below the 8-line minimum.
        let lines = [l(.removed)] + context(13) + [l(.added)]
        let sections = DiffSections.sections(for: lines, collapseThreshold: 12, padding: 4)
        XCTAssertEqual(sections.count, 3)
        guard case .unchanged(let middle, let collapsible) = sections[1] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(middle.count, 13)
        XCTAssertFalse(collapsible)
        XCTAssertEqual(allLines(sections), lines)
    }

    func testLeadingContextRunOnlyPadsTrailingEnd() {
        let lines = context(100) + [l(.added)]
        let sections = DiffSections.sections(for: lines)
        // No changed region above -> no leading padding piece, just collapsible + trailing padding.
        XCTAssertEqual(sections.count, 3)
        guard case .unchanged(let collapsible, let isCollapsible) = sections[0] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(collapsible.count, 96)
        XCTAssertTrue(isCollapsible)
        guard case .unchanged(let trail, let trailCollapsible) = sections[1] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(trail.count, 4)
        XCTAssertFalse(trailCollapsible)
        guard case .changed = sections[2] else { return XCTFail("expected changed") }
        XCTAssertEqual(allLines(sections), lines)
    }

    func testTrailingContextRunOnlyPadsLeadingEnd() {
        let lines = [l(.removed)] + context(100)
        let sections = DiffSections.sections(for: lines)
        XCTAssertEqual(sections.count, 3)
        guard case .changed = sections[0] else { return XCTFail("expected changed") }
        guard case .unchanged(let lead, let leadCollapsible) = sections[1] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(lead.count, 4)
        XCTAssertFalse(leadCollapsible)
        guard case .unchanged(let rest, let isCollapsible) = sections[2] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(rest.count, 96)
        XCTAssertTrue(isCollapsible)
        XCTAssertEqual(allLines(sections), lines)
    }

    func testHunkEntirelyContext() {
        // Not produced by real git output (a hunk always anchors at least one change), but the
        // pure function should still behave sensibly: no adjoining changed region on either side,
        // so no padding needed at all -- the whole run collapses if long enough.
        let lines = context(50)
        let sections = DiffSections.sections(for: lines)
        XCTAssertEqual(sections.count, 1)
        guard case .unchanged(let only, let collapsible) = sections[0] else { return XCTFail("expected unchanged") }
        XCTAssertEqual(only.count, 50)
        XCTAssertTrue(collapsible)
        XCTAssertEqual(allLines(sections), lines)
    }

    func testHunkWithNoContextLines() {
        let lines = [l(.removed), l(.removed), l(.added)]
        let sections = DiffSections.sections(for: lines)
        XCTAssertEqual(sections.count, 1)
        guard case .changed(let only) = sections[0] else { return XCTFail("expected changed") }
        XCTAssertEqual(only.count, 3)
        XCTAssertEqual(allLines(sections), lines)
    }

    func testConcatenationReproducesInputAcrossMultipleRuns() {
        let lines = context(2) + [l(.removed)] + context(50) + [l(.added), l(.added)] + context(3)
        let sections = DiffSections.sections(for: lines)
        XCTAssertEqual(allLines(sections), lines)
    }

    func testEmptyInput() {
        XCTAssertEqual(DiffSections.sections(for: []), [])
    }
}
