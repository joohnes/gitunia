import XCTest
@testable import GituniaCore

final class DiffLineSelectionTests: XCTestCase {
    private let diff = FileDiff(path: "x", isBinary: false, hunks: [
        Hunk(header: "@@ -1,3 +1,3 @@", lines: [
            DiffLine(kind: .context, text: "a", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .removed, text: "b", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .added, text: "B", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .context, text: "c", oldNumber: 3, newNumber: 3),
        ]),
        Hunk(header: "@@ -9,1 +9,2 @@", lines: [
            DiffLine(kind: .context, text: "i", oldNumber: 9, newNumber: 9),
            DiffLine(kind: .added, text: "j", oldNumber: nil, newNumber: 10),
        ]),
        Hunk(header: "@@ -20,1 +21,2 @@", lines: [
            DiffLine(kind: .added, text: "clipped", oldNumber: nil, newNumber: 21),
        ], isClipped: true),
    ])
    private func r(_ h: Int, _ l: Int) -> DiffLineRef { DiffLineRef(hunk: h, line: l) }

    func testPlainClickSelectsAndReclickClears() {
        let s1 = DiffLineSelection.click(r(0, 1), extend: false, toggle: false, selection: [r(1, 1)], anchor: r(1, 1), in: diff)
        XCTAssertEqual(s1.selection, [r(0, 1)]); XCTAssertEqual(s1.anchor, r(0, 1))
        let s2 = DiffLineSelection.click(r(0, 1), extend: false, toggle: false, selection: s1.selection, anchor: s1.anchor, in: diff)
        XCTAssertEqual(s2.selection, []); XCTAssertNil(s2.anchor)
    }

    func testContextAndClippedLinesAreNotSelectable() {
        for ref in [r(0, 0), r(0, 3), r(2, 0), r(5, 0)] {
            XCTAssertEqual(DiffLineSelection.click(ref, extend: false, toggle: false, selection: [], anchor: nil, in: diff).selection, [])
        }
    }

    func testShiftExtendsAcrossHunksSkippingContext() {
        let s = DiffLineSelection.click(r(1, 1), extend: true, toggle: false, selection: [r(0, 2)], anchor: r(0, 2), in: diff)
        XCTAssertEqual(s.selection, [r(0, 2), r(1, 1)])
        let back = DiffLineSelection.click(r(0, 1), extend: true, toggle: false, selection: s.selection, anchor: r(1, 1), in: diff)
        XCTAssertEqual(back.selection, [r(0, 1), r(0, 2), r(1, 1)])
    }

    func testCommandTogglesOneLine() {
        let s = DiffLineSelection.click(r(1, 1), extend: false, toggle: true, selection: [r(0, 1)], anchor: r(0, 1), in: diff)
        XCTAssertEqual(s.selection, [r(0, 1), r(1, 1)])
        let t = DiffLineSelection.click(r(0, 1), extend: false, toggle: true, selection: s.selection, anchor: s.anchor, in: diff)
        XCTAssertEqual(t.selection, [r(1, 1)])
    }
}
