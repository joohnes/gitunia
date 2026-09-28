import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of the pull-request popover's details (2 passing checks, 1 failing). Same
/// harness as `RemotesRenderTests`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter PullRequestRenderTests
@MainActor
final class PullRequestRenderTests: RenderTestCase {
    private let pr = PullRequest(
        number: 42, title: "Add pull-request awareness through the gh CLI", state: "OPEN",
        url: "https://github.com/acme/app/pull/42", isDraft: false, headRefName: "feat/pr-awareness",
        baseRefName: "main", reviewDecision: "CHANGES_REQUESTED",
        statusCheckRollup: [
            .init(typename: "CheckRun", name: "build (macos-15)", status: "COMPLETED", conclusion: "SUCCESS"),
            .init(typename: "StatusContext", context: "ci/circleci: test", state: "SUCCESS"),
            .init(typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "FAILURE"),
        ])

    func testRender_01_details() async throws {
        let view = PullRequestDetails(pr: pr, onOpen: {}).frame(width: 380)
        print("Rendered:", try await renderPNG(view, name: "pull-request-01-details", size: CGSize(width: 380, height: 300)))
    }

    func testRender_02_detailsDark() async throws {
        let view = PullRequestDetails(pr: pr, onOpen: {}).frame(width: 380)
        print("Rendered:", try await renderPNG(view, name: "pull-request-02-details-dark", size: CGSize(width: 380, height: 300), colorScheme: .dark))
    }
}
