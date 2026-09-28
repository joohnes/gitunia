import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for G2/T4 (Compare) — same technique as `BlameRenderTests`: a
/// real, offscreen-positioned `NSWindow` (AppKit toolbar/segmented-picker controls don't composite
/// for `cacheDisplay:` without one) hosting the real production views (`CompareView` +
/// `CompareDiffView`, side by side, mirroring `ContentView`'s content/detail columns), not a copy
/// of the UI. Also re-renders `CommitDiffView`'s header to confirm the parent link uses
/// `Theme.brand`, not the system-blue `Color.accentColor` a `.buttonStyle(.link)` defaults to.
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter CompareRenderTests
@MainActor
final class CompareRenderTests: RenderTestCase {
    /// `master` gets one commit after the branches split ("1 behind"); `feature` gets three commits
    /// touching a few different files/directories ("3 ahead") so tree mode has something to group.
    private func makeRepoAheadAndBehind() async throws -> (WorkspaceStore, RepositoryStore) {
        let root = try TestRepo.fixedRoot("compare")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, commit: false)

        func write(_ path: String, _ text: String) throws {
            let url = repoURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        try write("README.md", "hello\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "init"], date: TestRepo.fixedDate)

        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: repoURL)
        try write("src/auth/login.swift", "struct Login {}\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "feat: add login"], date: TestRepo.fixedDate.addingTimeInterval(3600))
        try write("src/auth/session.swift", "struct Session {}\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "feat: add session"], date: TestRepo.fixedDate.addingTimeInterval(7200))
        try write("docs/auth.md", "# Auth\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "docs: document auth"], date: TestRepo.fixedDate.addingTimeInterval(10_800))

        _ = try await git.run(["checkout", "-q", "master"], in: repoURL)
        try write("CHANGELOG.md", "- unrelated master change\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "chore: changelog"], date: TestRepo.fixedDate.addingTimeInterval(14_400))
        _ = try await git.run(["checkout", "-q", "feature"], in: repoURL)

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-compare-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else {
            throw XCTSkip("Repository did not scan into the workspace.")
        }
        await repo.refreshStatus()
        return (workspace, repo)
    }

    private func render(_ view: some View, name: String, size: CGSize) async throws -> String {
        try await render(view, names: [name], size: size, between: []).first ?? ""
    }

    /// Several snapshots of one hosted view; `between[i]` runs after snapshot `i`, before `i + 1`.
    /// Pinned light: offscreen renders can't draw system colours in dark appearance.
    private func render(_ view: some View, names: [String], size: CGSize, between: [() async throws -> Void]) async throws -> [String] {
        let (hosting, window) = hostOffscreen(view, size: size, appearance: .aqua)
        defer { window.orderOut(nil) }
        var paths: [String] = []
        for (i, name) in names.enumerated() {
            if i > 0 { try await between[i - 1]() }
            await pumpLayout(hosting)
            paths.append(try writePNG(hosting, name: name))
        }
        return paths
    }

    /// Hosts `CompareView` (content column) and `CompareDiffView` (detail column) side by side, the
    /// same pairing `ContentView` puts in its `NavigationSplitView` content/detail slots for
    /// `.compare` mode.
    private func compareColumns(
        workspace: WorkspaceStore, repo: RepositoryStore,
        base: Binding<String?>, head: Binding<String?>, selectedPath: Binding<String?>
    ) -> some View {
        HStack(spacing: 0) {
            CompareView(repo: repo, workspace: workspace, base: base, head: head, onOpenCommitInHistory: { _ in })
                .frame(width: 300)
            Divider()
            CompareDiffView(workspace: workspace, repo: repo, base: base.wrappedValue, head: head.wrappedValue, selectedPath: selectedPath)
        }
        .environment(ToastCenter())
        .environment(EditorOpenCoordinator())
    }

    /// `130-compare.png`: feature branch 3 ahead / 1 behind master, a few changed files, tree mode
    /// (the default — see `CompareDiffView.treeMode`'s `@AppStorage` default `true`).
    func testRender_compare() async throws {
        let (workspace, repo) = try await makeRepoAheadAndBehind()
        var base: String? = "master"
        var head: String?
        var selectedPath: String?
        let view = compareColumns(
            workspace: workspace, repo: repo,
            base: Binding(get: { base }, set: { base = $0 }),
            head: Binding(get: { head }, set: { head = $0 }),
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 })
        )
        let path = try await render(view, name: "130-compare", size: CGSize(width: 1000, height: 560))
        print("Rendered: \(path)")
    }

    /// `131-compare-empty.png`: head == base — both empty states (commit list and file diff) show
    /// at once.
    func testRender_compareEmpty() async throws {
        let (workspace, repo) = try await makeRepoAheadAndBehind()
        var base: String? = "master"
        var head: String? = "master"
        var selectedPath: String?
        let view = compareColumns(
            workspace: workspace, repo: repo,
            base: Binding(get: { base }, set: { base = $0 }),
            head: Binding(get: { head }, set: { head = $0 }),
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 })
        )
        let path = try await render(view, name: "131-compare-empty", size: CGSize(width: 1000, height: 560))
        print("Rendered: \(path)")
    }

    /// `133-compare-worktree.png`: head is an agent's worktree (`agent` branch, one uncommitted
    /// README edit + an untracked file) — the "Includes uncommitted changes in …" note shows above
    /// the diff and the head picker reads "<folder> · agent".
    func testRender_compareWorktree() async throws {
        let (workspace, repo) = try await makeRepoAheadAndBehind()
        let wtURL = FileManager.default.temporaryDirectory.appendingPathComponent("agent-wt-fx01")
        try? FileManager.default.removeItem(at: wtURL)
        _ = try await GitRunner().run(["worktree", "add", "-q", "-b", "agent", wtURL.path, "master"], in: repo.url)
        try "hello\nfrom the agent\n".write(to: wtURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "draft\n".write(to: wtURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        guard let wt = try await repo.worktrees().first(where: { $0.branch == "agent" }) else {
            throw XCTSkip("Worktree not listed.")
        }
        var base: String? = "master"
        var head: String? = CompareEndpoint.selection(for: wt)
        var selectedPath: String?
        let view = compareColumns(
            workspace: workspace, repo: repo,
            base: Binding(get: { base }, set: { base = $0 }),
            head: Binding(get: { head }, set: { head = $0 }),
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 })
        )
        // `133b`: the worktree isn't in the workspace, so only `CompareDiffView`'s fallback
        // FSEvents watcher can notice this edit — the README diff must show the new line.
        let paths = try await render(view, names: ["133-compare-worktree", "133b-compare-worktree-edited"],
                                     size: CGSize(width: 1000, height: 560), between: [{
            try "hello\nfrom the agent\nedited after render\n".write(to: wtURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(1))
        }])
        XCTAssertNil(workspace.repository(atPath: wtURL.path), "must exercise the unowned-worktree fallback")
        XCTAssertEqual(selectedPath, "README.md", "the selected file survives the refresh")
        print("Rendered: \(paths)")
    }

    /// `134-compare-worktree-store.png` → `134b-…-refreshed.png`: the worktree lives in the linked
    /// folder, so it has its own `RepositoryStore`; editing a file and refreshing *that* store
    /// (what `WorkspaceStore.handleChanges` does on FSEvents) must redraw the other repo's Compare.
    func testRender_compareWorktreeRefreshesFromItsStore() async throws {
        let (workspace, repo) = try await makeRepoAheadAndBehind()
        let wtURL = repo.url.deletingLastPathComponent().appendingPathComponent("agent-wt")
        _ = try await GitRunner().run(["worktree", "add", "-q", "-b", "agent", wtURL.path, "master"], in: repo.url)
        try "hello\nfrom the agent\n".write(to: wtURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        await workspace.rescanFolder(containing: wtURL)
        guard let wtStore = workspace.repository(atPath: wtURL.path),
              let wt = try await repo.worktrees().first(where: { $0.branch == "agent" }) else {
            throw XCTSkip("Worktree not scanned into the workspace.")
        }
        await wtStore.refreshStatus()
        var base: String? = "master"
        var head: String? = CompareEndpoint.selection(for: wt)
        var selectedPath: String?
        let view = compareColumns(
            workspace: workspace, repo: repo,
            base: Binding(get: { base }, set: { base = $0 }),
            head: Binding(get: { head }, set: { head = $0 }),
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 })
        )
        let before = wtStore.workingTreeVersion
        let paths = try await render(view, names: ["134-compare-worktree-store", "134b-compare-worktree-store-refreshed"],
                                     size: CGSize(width: 1000, height: 560), between: [{
            try "hello\nfrom the agent\nrefreshed via its store\n".write(to: wtURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            await wtStore.refreshStatus()
        }])
        XCTAssertGreaterThan(wtStore.workingTreeVersion, before)
        XCTAssertEqual(selectedPath, "README.md", "the selected file survives the refresh")
        print("Rendered: \(paths)")
    }

    /// `132-parent-link.png`: re-renders `CommitDiffView`'s header to confirm the parent hash link
    /// (`parentsRow`) now draws in `Theme.brand`, not the system-blue default `.buttonStyle(.link)`
    /// would otherwise use.
    func testRender_parentLinkUsesThemeBrand() async throws {
        let (workspace, repo) = try await makeRepoAheadAndBehind()
        let commits = await repo.history()
        // Newest-first; any non-root commit has a parent link. "feat: add session" is the second
        // feature commit, safely non-root.
        guard let commit = commits.first(where: { $0.subject == "feat: add session" }) else {
            throw XCTSkip("Expected commit not found.")
        }
        var selectedPath: String?
        let view = CommitDiffView(
            workspace: workspace, repo: repo, commit: commit,
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 }),
            selection: .constant(commit)
        )
        .environment(ToastCenter())
        .environment(EditorOpenCoordinator())
        let path = try await render(view, name: "132-parent-link", size: CGSize(width: 760, height: 260))
        print("Rendered: \(path)")
    }
}
