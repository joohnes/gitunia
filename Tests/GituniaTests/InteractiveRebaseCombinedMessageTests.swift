import XCTest
@testable import Gitunia
@testable import GituniaCore

final class InteractiveRebaseCombinedMessageTests: XCTestCase {
    @MainActor
    func testCombinedMessageStopsAtFirstPickBelow() {
        let rows = [RebaseTodo.Line(action: .squash, hash: "d", subject: "d"),
                    RebaseTodo.Line(action: .fixup, hash: "c", subject: "c"),
                    RebaseTodo.Line(action: .drop, hash: "x", subject: "x"),
                    RebaseTodo.Line(hash: "b", subject: "b"),
                    RebaseTodo.Line(hash: "a", subject: "a")]
        XCTAssertEqual(InteractiveRebaseSheetContent.combinedMessage(at: 0, in: rows), "b\n\nc\n\nd")
    }
}
