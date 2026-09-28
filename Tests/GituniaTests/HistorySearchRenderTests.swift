import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for G2/T1 (history search/paging/detail/merge-parent-picker) —
/// same technique as `CommitDiffTreeRenderTests`/`CommandPaletteRenderTests` (offscreen
/// `NSHostingView`, no Screen Recording permission needed).
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter HistorySearchRenderTests
@MainActor
final class HistorySearchRenderTests: RenderTestCase {
    private func makeWorkspace(_ repoURL: URL) async -> (WorkspaceStore, RepositoryStore) {
        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-history-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: repoURL.deletingLastPathComponent())
        return (workspace, workspace.repositories.first!)
    }

    private func host(_ view: some View, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        // Light, explicitly: semantic colours don't composite offscreen in dark mode.
        hostOffscreen(view.preferredColorScheme(.light), size: size, appearance: .aqua)
    }

    /// `100-history-filter.png`: a repo with several commits, some by "Alice" and some by "Bob" —
    /// the filter field pre-filled with `author:alice` (via `HistoryView.initialFilterText`, the
    /// same test-only-seam pattern `initialBranch` already uses), so the rendered list shows fewer
    /// commits than the repo actually has, and the field visibly shows the query.
    func testRender_historyFilter() async throws {
        let root = try TestRepo.fixedRoot("history-filter")
        let repoURL = root.appendingPathComponent("Backend")
        try await TestRepo.make(at: repoURL, commit: false)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "alice: first fix", "--author=Alice <alice@x.com>"], date: TestRepo.fixedDate)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "bob: unrelated change", "--author=Bob <bob@x.com>"], date: TestRepo.fixedDate.addingTimeInterval(3600))
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "alice: second fix", "--author=Alice <alice@x.com>"], date: TestRepo.fixedDate.addingTimeInterval(7200))
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "bob: another one", "--author=Bob <bob@x.com>"], date: TestRepo.fixedDate.addingTimeInterval(10_800))

        let (_, repo) = await makeWorkspace(repoURL)
        let toasts = ToastCenter()
        var selection: CommitInfo?
        let view = HistoryView(
            repo: repo,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            initialFilterText: "author:alice"
        ).environment(toasts)
        let (hosting, window) = host(view, size: CGSize(width: 360, height: 420))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        let path = try writePNG(hosting, name: "100-history-filter")
        print("Rendered: \(path)")
    }

    /// `101-commit-detail.png`: a commit with a multi-line body and author != committer (authored
    /// by "Alice", committed by "Test" via the temp repo's own configured identity — same shape
    /// `HistoryTests.testCommitDetailMultiLineBodyAndAuthorNotCommitter` verifies against real git).
    func testRender_commitDetail() async throws {
        let root = try TestRepo.fixedRoot("commit-detail")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, commit: false)
        try "hello\n".write(to: repoURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: [
            "-q", "-m",
            "feat: teach the parser about multi-line bodies\n\nFirst paragraph explaining the motivation for this change in more detail than a subject line allows.\n\nSecond paragraph with more context, so the header has to actually wrap and show several lines of body text below the bold subject.",
            "--author=Alice <alice@example.com>",
        ], date: TestRepo.fixedDate)

        let (workspace, repo) = await makeWorkspace(repoURL)
        let commits = await repo.history()
        guard let commit = commits.first else { throw XCTSkip("Expected at least one commit.") }
        let toasts = ToastCenter()
        let editorRequests = EditorOpenCoordinator()
        var selectedPath: String?
        var selection: CommitInfo? = commit
        let view = CommitDiffView(
            workspace: workspace, repo: repo, commit: commit,
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 })
        ).environment(toasts).environment(editorRequests)
        let (hosting, window) = host(view, size: CGSize(width: 700, height: 420))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        let path = try writePNG(hosting, name: "101-commit-detail")
        print("Rendered: \(path)")
    }

    /// Commit detail header: readable relative dates (author 3 days back via `--date`, committer
    /// "just now"), absolute date on hover.
    func testRender_integCommitDetailDates() async throws {
        let root = try TestRepo.fixedRoot("commit-dates")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, commit: false)
        try "hello\n".write(to: repoURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repoURL)
        // Fixed author date 3 days behind the fixed committer date (env, via `TestRepo.commit`'s
        // `date:`) — both absolute, not `Date()`-relative, so the commit hash (and any rendered
        // relative-date bucket) is stable across runs.
        let threeDaysAgo = ISO8601DateFormatter().string(from: TestRepo.fixedDate.addingTimeInterval(-3 * 86_400))
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "fix: readable dates", "--author=Alice <alice@example.com>", "--date=\(threeDaysAgo)"], date: TestRepo.fixedDate)

        let (workspace, repo) = await makeWorkspace(repoURL)
        guard let commit = await repo.history().first else { throw XCTSkip("Expected a commit.") }
        var selectedPath: String?
        var selection: CommitInfo? = commit
        let view = CommitDiffView(
            workspace: workspace, repo: repo, commit: commit,
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 })
        ).environment(ToastCenter()).environment(EditorOpenCoordinator())
        let (hosting, window) = host(view, size: CGSize(width: 700, height: 260))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        print("Rendered: \(try writePNG(hosting, name: "integ-03-commit-detail-dates"))")
    }

    /// `fix-content-01-history-dates.png` (M12): history list rows show a readable relative date
    /// ("3 days ago", "just now") instead of the raw `--date=short` value, via `HistoryRowDate`.
    func testRender_historyRowDates() async throws {
        let root = try TestRepo.fixedRoot("history-dates")
        let repoURL = root.appendingPathComponent("Backend")
        try await TestRepo.make(at: repoURL, commit: false)
        let threeDaysAgo = ISO8601DateFormatter().string(from: TestRepo.fixedDate.addingTimeInterval(-3 * 86_400))
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "older: three days back", "--date=\(threeDaysAgo)"], date: TestRepo.fixedDate)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "newest: just now"], date: TestRepo.fixedDate.addingTimeInterval(3 * 86_400))

        let (_, repo) = await makeWorkspace(repoURL)
        let toasts = ToastCenter()
        var selection: CommitInfo?
        let view = HistoryView(repo: repo, selection: Binding(get: { selection }, set: { selection = $0 }))
            .environment(toasts)
        let (hosting, window) = host(view, size: CGSize(width: 360, height: 240))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        let path = try writePNG(hosting, name: "fix-content-01-history-dates")
        print("Rendered: \(path)")
    }

    /// `history-unreviewed.png`: review point at the 2nd of 4 commits, "Unreviewed" chip on with a
    /// count of 2 — the list shows only the two newer commits.
    func testRender_unreviewedChip() async throws {
        let root = try TestRepo.fixedRoot("history-unreviewed")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, commit: false)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "one: reviewed"], date: TestRepo.fixedDate)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "two: reviewed (review point)"], date: TestRepo.fixedDate.addingTimeInterval(3600))
        let reviewed = try await git.run(["rev-parse", "HEAD"], in: repoURL).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "three: agent commit"], date: TestRepo.fixedDate.addingTimeInterval(7200))
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "four: agent commit"], date: TestRepo.fixedDate.addingTimeInterval(10_800))

        let (_, repo) = await makeWorkspace(repoURL)
        repo.reviewedHead = reviewed
        await repo.refreshStatus()
        XCTAssertEqual(repo.unreviewedCount, 2)
        var selection: CommitInfo?
        let view = HistoryView(repo: repo, selection: Binding(get: { selection }, set: { selection = $0 }),
                               initialUnreviewedOnly: true)
            .environment(ToastCenter())
        let (hosting, window) = host(view, size: CGSize(width: 420, height: 300))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        print("Rendered: \(try writePNG(hosting, name: "history-unreviewed"))")
    }

    /// `history-agent-commits.png`: "Agent commits" chip on — only the two `bot@example.com`
    /// commits are listed, each with the `cpu` glyph before the author; the human commit is hidden.
    func testRender_agentCommitsChip() async throws {
        let root = try TestRepo.fixedRoot("history-agent")
        let repoURL = root.appendingPathComponent("Backend")
        try await TestRepo.make(at: repoURL, commit: false)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "feat: agent scaffolding"],
                                      date: TestRepo.fixedDate, user: "Builder", email: "bot@example.com")
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "fix: human touch-up"],
                                      date: TestRepo.fixedDate.addingTimeInterval(3600))
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "--allow-empty", "-m", "refactor: agent follow-up"],
                                      date: TestRepo.fixedDate.addingTimeInterval(7200), user: "Builder", email: "bot@example.com")

        let (_, repo) = await makeWorkspace(repoURL)
        repo.globalAgentProfile = AgentProfile(patterns: AgentProfile.defaultPatterns + ["bot@"])
        let history = await repo.history()
        XCTAssertEqual(history.filter { repo.agentProfile.matches(author: $0.author, email: $0.authorEmail) }.count, 2)
        var selection: CommitInfo?
        let view = HistoryView(repo: repo, selection: Binding(get: { selection }, set: { selection = $0 }),
                               initialAgentOnly: true)
            .environment(ToastCenter())
        let (hosting, window) = host(view, size: CGSize(width: 420, height: 300))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        print("Rendered: \(try writePNG(hosting, name: "history-agent-commits"))")
    }

    /// `102-merge-parent-picker.png`: a merge commit, header shows the "Diff against: parent 1 /
    /// parent 2" segmented picker (only merge commits get it — see `CommitDiffView.parentPicker`).
    func testRender_mergeParentPicker() async throws {
        let root = try TestRepo.fixedRoot("merge-picker")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, files: ["base.txt": "base\n"])
        _ = try await git.run(["checkout", "-q", "-b", "feat"], in: repoURL)
        try "feat\n".write(to: repoURL.appendingPathComponent("feat.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "feat commit"], date: TestRepo.fixedDate.addingTimeInterval(3600))
        _ = try await git.run(["checkout", "-q", "master"], in: repoURL)
        try "master\n".write(to: repoURL.appendingPathComponent("master.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "master commit"], date: TestRepo.fixedDate.addingTimeInterval(7200))
        // `merge` isn't a `commit` subcommand, so it can't go through `TestRepo.commit` — pin its
        // committer date (the only one a merge commit has, absent `--author`) the same way.
        let mergeDate = ISO8601DateFormatter().string(from: TestRepo.fixedDate.addingTimeInterval(10_800))
        _ = try await git.runCombined(["merge", "-q", "--no-ff", "-m", "merge feat into master", "feat"], in: repoURL, extraEnvironment: [
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_AUTHOR_DATE": mergeDate,
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com", "GIT_COMMITTER_DATE": mergeDate,
        ])

        let (workspace, repo) = await makeWorkspace(repoURL)
        let commits = await repo.history()
        guard let merge = commits.first, merge.parentCount > 1 else { throw XCTSkip("Expected a merge commit first.") }
        let toasts = ToastCenter()
        let editorRequests = EditorOpenCoordinator()
        var selectedPath: String?
        var selection: CommitInfo? = merge
        let view = CommitDiffView(
            workspace: workspace, repo: repo, commit: merge,
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 })
        ).environment(toasts).environment(editorRequests)
        let (hosting, window) = host(view, size: CGSize(width: 700, height: 420))
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)
        let path = try writePNG(hosting, name: "102-merge-parent-picker")
        print("Rendered: \(path)")
    }
}
