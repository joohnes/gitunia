import XCTest
@testable import GituniaCore

final class RepoEventsTests: XCTestCase {
    private let base = RepoEvent.Snapshot(headOID: "aaa", branches: ["main"], operation: nil)

    func testNoChangeIsEmpty() {
        XCTAssertEqual(RepoEvent.diff(old: base, new: base), [])
    }

    func testHeadMoved() {
        var new = base; new.headOID = "bbb"
        XCTAssertEqual(RepoEvent.diff(old: base, new: new), [.headMoved(from: "aaa", to: "bbb")])
    }

    func testBranchAddedButNotRemoved() {
        var new = base; new.branches = ["feat", "zeta"]
        XCTAssertEqual(RepoEvent.diff(old: base, new: new), [.branchAdded("feat"), .branchAdded("zeta")])
    }

    func testOperationStartedOnlyOnTransition() {
        var new = base; new.operation = .rebase
        XCTAssertEqual(RepoEvent.diff(old: base, new: new), [.operationStarted(.rebase)])
        XCTAssertEqual(RepoEvent.diff(old: new, new: new), [])
    }

    func testCoalescerFixedWindowPerKey() {
        var t = Date(timeIntervalSince1970: 0)
        var c = EventCoalescer(window: 10, now: { t })
        XCTAssertTrue(c.shouldDeliver("a"))
        XCTAssertTrue(c.shouldDeliver("b"))
        t += 9
        XCTAssertFalse(c.shouldDeliver("a"))
        t += 1
        XCTAssertTrue(c.shouldDeliver("a"))
    }
}
