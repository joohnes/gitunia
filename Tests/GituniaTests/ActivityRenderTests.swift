import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `ActivityView` over a temp `ActivityLog` (same harness as `RemotesRenderTests`).
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter ActivityRenderTests
@MainActor
final class ActivityRenderTests: RenderTestCase {
    private func makeLog() -> ActivityLog {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-activity-\(UUID().uuidString).json")
        let log = ActivityLog(fileURL: file)
        let now = Date()
        func c(_ h: String, _ s: String, _ a: String, _ ago: Double) -> ActivityCommit {
            ActivityCommit(hash: h + String(repeating: "0", count: 33), subject: s, author: a, authorEmail: "\(a)@x", date: now.addingTimeInterval(-ago))
        }
        func e(_ repo: String, _ kind: ActivityEventKind, _ ref: String, _ commits: [ActivityCommit], ago: Double,
               pr: Int? = nil, title: String? = nil, seen: Bool = false) -> ActivityEvent {
            ActivityEvent(repoPath: "/tmp/\(repo)", repoName: repo, kind: kind, ref: ref, oldOID: "a\(ago)", newOID: "b\(ago)",
                          commits: commits, pullRequestNumber: pr, pullRequestTitle: title, date: now.addingTimeInterval(-ago), seen: seen)
        }
        log.append([
            e("api", .pullRequestMerged, "origin/main", [c("1a2b3c4", "Add rate limiter (#42)", "agent-1", 600)], ago: 600, pr: 42, title: "Add rate limiter"),
            e("api", .baseAdvanced, "origin/main", [c("1a2b3c4", "Add rate limiter (#42)", "agent-1", 600)], ago: 610),
            e("api", .branchCreated, "origin/feat-cache", [c("5d6e7f8", "Cache warmup", "agent-2", 3600), c("9a8b7c6", "Cache keys", "agent-2", 3700)], ago: 3600),
            e("api", .forcePushed, "origin/feat-auth", [c("abcdef1", "Rewrite token refresh", "agent-1", 7200)], ago: 7200),
            e("web", .branchUpdated, "origin/feat-x", [c("1111111", "Tweak layout", "agent-3", 4000), c("2222222", "Fix nav", "agent-3", 4100), c("3333333", "Lint", "agent-3", 4200)], ago: 4000, seen: true),
            e("web", .branchDeleted, "origin/old-spike", [], ago: 90_000, seen: true),
            e("web", .pullRequestMerged, "origin/main", [c("4444444", "Merge pull request #7 from acme/feat-y", "agent-3", 95_000)], ago: 95_000, pr: 7, seen: true),
            e("web", .branchCreated, "origin/feat-z", [c("5555555", "Scaffold", "agent-1", 100_000)], ago: 100_000),
        ])
        return log
    }

    func testRender_01_allRepositories() async throws {
        let log = makeLog()
        XCTAssertEqual(log.digest(since: ActivityRange.week.since()).count, 2)
        print("Rendered:", try await renderPNG(ActivityView(log: log), name: "activity-01-all", size: CGSize(width: 900, height: 600)))
    }

    func testRender_02_repoWithStaleBranches() async throws {
        let now = Date()
        let stale = [StaleBranch(ref: "origin/feat-old", lastCommit: now.addingTimeInterval(-40 * 86_400), author: "agent-2", merged: false),
                     StaleBranch(ref: "origin/feat-done", lastCommit: now.addingTimeInterval(-2 * 86_400), author: "agent-1", merged: true)]
        let view = ActivityView(log: makeLog(), selection: "/tmp/api", preloadedStale: ["/tmp/api": stale])
        // `ActivityWindow` marks the selected repo's events seen (bold → regular) after a fixed 2s
        // dwell — the default ~2s of `pumpLayout` ticks races that timer, so bump past it (D18).
        print("Rendered:", try await renderPNG(view, name: "activity-02-repo-stale", size: CGSize(width: 900, height: 600), ticks: 35))
    }
}
