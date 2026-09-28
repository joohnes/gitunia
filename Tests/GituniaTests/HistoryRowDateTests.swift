import XCTest
@testable import Gitunia

/// M12: `HistoryRowDate` turns `CommitInfo.date`'s short `--date=short` form ("2024-01-15") into a
/// relative string for the history list row, with the exact date available as a tooltip — same
/// rule `CommitDiffView.readable`/`.absolute` already apply to the detail header, just parsing the
/// coarser format `LogParser` gives this list.
@MainActor
final class HistoryRowDateTests: XCTestCase {
    func testReadableIsRelativeForARecentDate() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let short = shortDateString(yesterday)
        XCTAssertNotEqual(HistoryRowDate.readable(short), short, "should not just echo the raw short date back")
    }

    func testUnparsableInputFallsBackToTheRawString() {
        XCTAssertEqual(HistoryRowDate.readable("not-a-date"), "not-a-date")
        XCTAssertEqual(HistoryRowDate.absolute("not-a-date"), "not-a-date")
    }

    func testAbsoluteRoundTripsARecognizableDate() {
        // Just needs to actually parse (not fall back to the raw string) and produce something
        // date-shaped — exact formatting is locale-dependent and covered by `RelativeDate` itself.
        XCTAssertNotEqual(HistoryRowDate.absolute("2024-01-15"), "2024-01-15")
    }

    private func shortDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
