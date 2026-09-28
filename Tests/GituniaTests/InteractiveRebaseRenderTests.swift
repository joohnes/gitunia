import XCTest
import SwiftUI
import AppKit
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

/// Offscreen render of the Tidy Commits sheet with injected commits, one row set to squash with
/// its message field showing. Same harness as `RemotesRenderTests`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter InteractiveRebaseRenderTests
@MainActor
final class InteractiveRebaseRenderTests: RenderTestCase {
    private let rows: [RebaseTodo.Line] = [
        RebaseTodo.Line(action: .fixup, hash: "9f3c2a1b7e", subject: "wip: fix typo"),
        RebaseTodo.Line(action: .squash, hash: "7a1d4e9c02", subject: "Add retry to fetch loop",
                        newMessage: "Add fetch retry with backoff\n\nRetries three times before surfacing the error."),
        RebaseTodo.Line(hash: "5be8f0d3aa", subject: "Add backoff helper"),
        RebaseTodo.Line(action: .drop, hash: "31c07b6d44", subject: "debug logging, do not ship"),
        RebaseTodo.Line(action: .reword, hash: "0e2b9c8f11", subject: "stuff", newMessage: "Extract RemoteClient from RepositoryStore"),
    ]

    func testRender_01_squashRow() async throws {
        let view = InteractiveRebaseSheetContent(blocker: nil, isLoading: false, rows: .constant(rows), error: nil,
                                                 onCancel: {}, onRebase: {})
        print("Rendered:", try await renderPNG(view, name: "tidy-01-squash", size: CGSize(width: 560, height: 560)))
    }

    func testRender_02_blocked() async throws {
        let view = InteractiveRebaseSheetContent(blocker: "2 uncommitted changes — stash or commit first", isLoading: false,
                                                 rows: .constant([]), error: nil, onCancel: {}, onRebase: {})
        print("Rendered:", try await renderPNG(view, name: "tidy-02-blocked", size: CGSize(width: 560, height: 260), colorScheme: .dark))
    }
}
