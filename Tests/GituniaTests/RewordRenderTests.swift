import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `RewordCommitSheet` over a real repo whose HEAD is already pushed (pushed
/// warning) and carries an agent trailer (the "Removed 1 agent trailer" note).
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter RewordRenderTests
@MainActor
final class RewordRenderTests: RenderTestCase {
    private func makeStore() async throws -> RepositoryStore {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-reword-render-\(UUID().uuidString)")
        let url = base.appendingPathComponent("app")
        let message = "feat: add login\n\nWires the form to the session API.\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
        try await TestRepo.make(at: url, message: message, user: "T", email: "t@example.com")
        for args in [["init", "-q", "-b", "master", "--bare", base.appendingPathComponent("origin.git").path],
                     ["remote", "add", "origin", base.appendingPathComponent("origin.git").path],
                     ["push", "-q", "-u", "origin", "master"]] {
            _ = try await GitRunner().run(args, in: url)
        }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return store
    }

    func testRender_01_pushedWithStrippedTrailer() async throws {
        let store = try await makeStore()
        XCTAssertTrue(store.hasUpstream)
        XCTAssertEqual(store.repo.ahead, 0)
        let sheet = RewordCommitSheet(repo: store, stripTrailers: true).environment(ToastCenter())
        print("Rendered:", try await renderPNG(sheet, name: "reword-01-pushed", size: CGSize(width: 520, height: 360)))
    }
}
