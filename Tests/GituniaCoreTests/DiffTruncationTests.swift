import XCTest
@testable import GituniaCore

final class DiffTruncationTests: XCTestCase {
    func testTruncatesAcrossHunks() {
        func line(_ n: Int) -> DiffLine {
            DiffLine(kind: .context, text: "line \(n)", oldNumber: n, newNumber: n)
        }
        let hunkA = Hunk(header: "@@ -1,5 +1,5 @@", lines: (0..<5).map(line))
        let hunkB = Hunk(header: "@@ -10,5 +10,5 @@", lines: (0..<5).map(line))
        let diff = FileDiff(path: "f.txt", isBinary: false, hunks: [hunkA, hunkB])

        let (truncated, total) = diff.truncated(toLines: 7)
        XCTAssertEqual(total, 10)
        XCTAssertEqual(truncated.hunks.count, 2)
        XCTAssertEqual(truncated.hunks[0].lines.count, 5)
        XCTAssertEqual(truncated.hunks[1].lines.count, 2)
        XCTAssertFalse(truncated.hunks[0].isClipped)
        XCTAssertTrue(truncated.hunks[1].isClipped)
    }
}
