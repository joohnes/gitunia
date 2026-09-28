import XCTest
@testable import Gitunia

/// H3: `HistoryPaging.limit` decides how many commits to (re)fetch when `HistoryView`'s
/// `.task(id:)` reruns. A real branch/filter/repo change always resets to one page; a same-context
/// rerun (a new commit landed while more pages were loaded) must not throw away pages already
/// fetched via "Load More".
final class HistoryPagingTests: XCTestCase {
    func testRealContextChangeAlwaysResetsToOnePage() {
        XCTAssertEqual(HistoryPaging.limit(sameContext: false, currentCount: 600, pageSize: 200), 200)
    }

    func testSameContextRerunKeepsAtLeastWhatWasAlreadyLoaded() {
        XCTAssertEqual(HistoryPaging.limit(sameContext: true, currentCount: 600, pageSize: 200), 600)
    }

    func testSameContextRerunNeverFetchesFewerThanOnePage() {
        // Fewer than one page loaded so far (no "Load More" yet) still asks for a full page.
        XCTAssertEqual(HistoryPaging.limit(sameContext: true, currentCount: 40, pageSize: 200), 200)
    }

    func testFirstLoadInAFreshContextIsExactlyOnePage() {
        XCTAssertEqual(HistoryPaging.limit(sameContext: false, currentCount: 0, pageSize: 200), 200)
    }
}
