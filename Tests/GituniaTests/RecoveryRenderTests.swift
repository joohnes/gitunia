import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen renders of the real recovery views (reflog sheet, reset sheet, History header,
/// detached sidebar row). Menus and confirmation dialogs don't composite offscreen.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter RecoveryRenderTests
@MainActor
final class RecoveryRenderTests: RenderTestCase {
    private func render(_ view: some View, name: String, size: CGSize) async throws {
        // Light, explicitly: semantic colours don't composite offscreen in dark mode.
        _ = try await renderHostedPNG(view.preferredColorScheme(.light), name: name, size: size, appearance: .aqua)
    }

    /// A workspace with one repo "Backend": init, two commits, an amend, a pushed marker, a hard
    /// reset that undid a commit, and uncommitted work.
    private func makeWorkspace() async throws -> (WorkspaceStore, RepositoryStore) {
        let root = try TestRepo.fixedRoot("recovery")
        let url = root.appendingPathComponent("Backend")
        let git = GitRunner()
        func run(_ args: [String]) async throws { _ = try await git.run(args, in: url) }
        func commit(_ args: [String], offset: TimeInterval) async throws { _ = try await TestRepo.commit(at: url, args: args, date: TestRepo.fixedDate.addingTimeInterval(offset)) }
        func write(_ name: String, _ text: String) throws { try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
        try write("api.swift", "v1\n")
        try await run(["add", "."]); try await commit(["-q", "-m", "Add API client"], offset: 3600)
        try await run(["update-ref", "refs/remotes/origin/master", "HEAD"])
        try write("api.swift", "v2\n")
        try await commit(["-q", "-am", "Retry failed requests"], offset: 7200)
        try await commit(["-q", "--amend", "-m", "Retry failed requests with backoff"], offset: 7200)
        try write("cache.swift", "c\n")
        try await run(["add", "."]); try await commit(["-q", "-m", "Agent: rewrite cache layer"], offset: 10_800)
        try await run(["reset", "-q", "--hard", "HEAD~1"])
        try await run(["checkout", "-q", "-b", "feature/login"])
        try await run(["checkout", "-q", "master"])
        try write("README.md", "hello\nwip notes\n")
        try write("api.swift", "v3 in progress\n")
        try await run(["add", "api.swift"])
        try write("scratch.txt", "untracked\n")

        let config = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-recovery-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: config))
        await workspace.openUntitled(linkingFolder: root)
        guard let store = workspace.repositories.first else { throw XCTSkip("Repository did not scan") }
        await store.refreshStatus()
        return (workspace, store)
    }

    func testRender_reflogSheet() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let view = ReflogSheet(store: store, onDone: {})
            .environment(ToastCenter()).environment(RecoveryCoordinator())
        try await render(view, name: "recovery-01-reflog-sheet", size: CGSize(width: 680, height: 440))
    }

    /// "Stashed by Gitunia" above the reflog: one auto-stash on master (current, 3 files), one on
    /// feature/login ("made on another branch"); a manual stash stays out of the section.
    func testRender_reflogSheetWithGituniaStashes() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        // Stash entries are commits `RepositoryStore` makes itself (real "now" dates by default) —
        // pin the process-wide git clock so their hashes are stable too (D18).
        var ok = await TestRepo.withFixedGitClock(date: TestRepo.fixedDate.addingTimeInterval(20_000)) { await store.autoStash() }
        XCTAssertTrue(ok)
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "feature/login"], in: store.url)
        try "agent wip\n".write(to: store.url.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        await store.refreshStatus()
        ok = await TestRepo.withFixedGitClock(date: TestRepo.fixedDate.addingTimeInterval(23_600)) { await store.autoStash() }
        XCTAssertTrue(ok)
        try "manual\n".write(to: store.url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        await store.refreshStatus()
        ok = await TestRepo.withFixedGitClock(date: TestRepo.fixedDate.addingTimeInterval(27_200)) { await store.stash(message: "by hand") }
        XCTAssertTrue(ok)
        _ = try await git.run(["checkout", "-q", "master"], in: store.url)
        await store.refreshStatus()
        let ours = await store.gituniaStashes()
        XCTAssertEqual(ours.count, 2)
        let view = ReflogSheet(store: store, onDone: {})
            .environment(ToastCenter()).environment(RecoveryCoordinator())
        try await render(view, name: "recovery-05-reflog-gitunia-stashes", size: CGSize(width: 680, height: 480))
    }

    private func plan(_ store: RepositoryStore) async throws -> ResetPlan {
        let root = try await GitRunner().run(["rev-list", "--max-parents=0", "HEAD"], in: store.url).trimmingCharacters(in: .whitespacesAndNewlines)
        let impact = await store.resetImpact(to: root)
        return ResetPlan(store: store, branch: "master", targetHash: root, targetShortHash: String(root.prefix(7)),
                         targetSubject: "init", headAtRequest: await store.headHash(), impact: impact,
                         warnings: Preflight.checkReset(repo: store.repo, operation: nil, impact: impact),
                         lostFiles: store.repo.filesLostByHardReset)
    }

    func testRender_resetSheetHard() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let p = try await plan(store)
        XCTAssertEqual(p.impact, ResetImpact(undone: 2, pushed: 1))
        try await render(ResetSheet(plan: p, initialMode: .hard, onCancel: {}, onReset: { _ in }),
                         name: "recovery-02-reset-sheet-hard", size: CGSize(width: 480, height: 560))
    }

    func testRender_resetSheetMixed() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let p = try await plan(store)
        try await render(ResetSheet(plan: p, onCancel: {}, onReset: { _ in }),
                         name: "recovery-03-reset-sheet-mixed", size: CGSize(width: 480, height: 420))
    }

    /// History's header with the Reflog button, and the sidebar row reading "Detached at <hash>".
    func testRender_historyHeaderAndDetachedSidebar() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        _ = await TestRepo.withFixedGitClock(date: TestRepo.fixedDate.addingTimeInterval(20_000)) { await store.stash() }
        let root = try await GitRunner().run(["rev-list", "--max-parents=0", "HEAD"], in: store.url).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await store.checkoutDetached(root)
        XCTAssertEqual(store.repo.branchLabel, "Detached at \(root.prefix(7))")
        workspace.selectedRepoID = store.id
        var selection: CommitInfo?
        let history = HistoryView(repo: store, selection: Binding(get: { selection }, set: { selection = $0 }))
        let view = HStack(spacing: 0) {
            SidebarView(workspace: workspace).frame(width: 260)
            Divider()
            history.frame(width: 360)
        }
        .environment(ToastCenter()).environment(RemoteOpsCoordinator()).environment(RecoveryCoordinator())
        try await render(view, name: "recovery-04-history-header-detached", size: CGSize(width: 621, height: 300))
    }

    // MARK: - Integration round renders

    /// Hard reset that discards files: the button reads destructive (red).
    func testRender_integResetHardDestructive() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        let p = try await plan(store)
        XCTAssertFalse(p.lostFiles.isEmpty)
        try await render(ResetSheet(plan: p, initialMode: .hard, onCancel: {}, onReset: { _ in }),
                         name: "integ-01-reset-hard-destructive", size: CGSize(width: 480, height: 560))
    }

    /// History's branch picker while detached shows "Detached at <hash>" instead of blank.
    func testRender_integHistoryDetachedPicker() async throws {
        let (workspace, store) = try await makeWorkspace()
        defer { workspace.stopWatching() }
        _ = await TestRepo.withFixedGitClock(date: TestRepo.fixedDate.addingTimeInterval(20_000)) { await store.stash() }
        let root = try await GitRunner().run(["rev-list", "--max-parents=0", "HEAD"], in: store.url).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await store.checkoutDetached(root)
        XCTAssertTrue(store.repo.isDetached)
        var selection: CommitInfo?
        let view = HistoryView(repo: store, selection: Binding(get: { selection }, set: { selection = $0 }))
            .environment(ToastCenter()).environment(RemoteOpsCoordinator()).environment(RecoveryCoordinator())
        try await render(view, name: "integ-02-history-detached-picker", size: CGSize(width: 360, height: 220))
    }
}
