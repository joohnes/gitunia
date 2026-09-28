import XCTest
@testable import GituniaCore

final class RepoEventsTests: XCTestCase {
    private let base = RepoEvent.Snapshot(headOID: "aaa", branches: ["main"], operation: nil)

    func testDiffTable() {
        var moved = base; moved.headOID = "bbb"
        var branched = base; branched.branches = ["feat", "zeta"]
        var rebasing = base; rebasing.operation = .rebase
        let cases: [(name: String, old: RepoEvent.Snapshot, new: RepoEvent.Snapshot, expected: [RepoEvent])] = [
            ("no change", base, base, []),
            ("head moved", base, moved, [.headMoved(from: "aaa", to: "bbb")]),
            ("branch added, not removed", base, branched, [.branchAdded("feat"), .branchAdded("zeta")]),
            ("operation started", base, rebasing, [.operationStarted(.rebase)]),
            ("operation still running", rebasing, rebasing, []),
        ]
        for c in cases {
            XCTAssertEqual(RepoEvent.diff(old: c.old, new: c.new), c.expected, c.name)
        }
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
