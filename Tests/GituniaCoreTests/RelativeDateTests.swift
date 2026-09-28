import XCTest
@testable import GituniaCore

@MainActor
final class RelativeDateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWithinAMinuteOrFutureIsJustNow() {
        XCTAssertEqual(RelativeDate.string(for: now, relativeTo: now), "just now")
        XCTAssertEqual(RelativeDate.string(for: now.addingTimeInterval(-59), relativeTo: now), "just now")
        XCTAssertEqual(RelativeDate.string(for: now.addingTimeInterval(30), relativeTo: now), "just now")
    }

    func testOlderIsRelative() {
        let s = RelativeDate.string(for: now.addingTimeInterval(-3 * 86_400), relativeTo: now)
        XCTAssertNotEqual(s, "just now")
        XCTAssertTrue(s.contains("3"), s)
    }

    func testParsesISOStrict() {
        XCTAssertEqual(RelativeDate.parseISO("2026-09-23T15:59:48+02:00")?.timeIntervalSince1970, 1_790_171_988)
        XCTAssertNil(RelativeDate.parseISO("not a date"))
    }
}
