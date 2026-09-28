import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `PostReportSheet` in "PR comment" mode with injected open PRs (no gh run).
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter PostReportRenderTests
@MainActor
final class PostReportRenderTests: RenderTestCase {
    func testRender_01_prComment() async throws {
        let prs = [PullRequest(number: 12, title: "Add the thing", state: "OPEN", url: "https://github.com/acme/app/pull/12",
                               isDraft: false, headRefName: "agent/feat-x", baseRefName: ""),
                   PullRequest(number: 13, title: "Fix flaky test", state: "OPEN", url: "https://github.com/acme/app/pull/13",
                               isDraft: false, headRefName: "agent/fix-y", baseRefName: "")]
        let report = """
        # Activity since Sep 17, 2026

        ## app
        - Merged #11 · Tighten retry loop
        - agent/feat-x · 3 commits by claude-bot
        - Force-pushed agent/fix-y
        """
        let sheet = PostReportSheet(store: RepositoryStore(url: URL(fileURLWithPath: "/tmp")), slug: "acme/app",
                                    report: report, rangeLabel: "Sep 17 – Sep 24, 2026", toasts: nil, pullRequests: prs)
        print("Rendered:", try await renderPNG(sheet, name: "post-report-01-pr-comment", size: CGSize(width: 600, height: 500)))
    }
}
