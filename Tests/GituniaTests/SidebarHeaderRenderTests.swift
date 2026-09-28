import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for item 2 of the layout/tree/edit design: the sidebar header's
/// old tag `Picker` + `↑↓` toggle ("looks weak, not clear what it is") replaced by a "Filter
/// repositories" search field with a trailing sort menu, and a row of scope chips with counts
/// (`All 6`, `Changed 3`, then one chip per tag).
///
/// Same real-offscreen-window technique as `ChangesViewRenderTests` — `SidebarView` hosts a
/// `List`, which is `NSTableView`-backed and needs a real (if offscreen-positioned) `NSWindow` to
/// composite for a `cacheDisplay:` snapshot; see that file's doc comment for how this was found.
///
/// Disabled by default, same env var as the other render harnesses:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter SidebarHeaderRenderTests
@MainActor
final class SidebarHeaderRenderTests: RenderTestCase {
    /// 6 repos: `api` and `worker` have working-tree changes, `scheduler` is ahead of its upstream
    /// with a clean working tree (so "Changed" must include it via ahead/behind, not just
    /// `hasChanges`), `frontend` and `docs` are tagged `work`, `infra` is untagged and clean.
    /// `withRebase` adds `billing`, stopped on a conflicting `git rebase` (sidebar warning icon).
    private func makeFixtureWorkspace(withRebase: Bool = false) async throws -> WorkspaceStore {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-sidebar-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let git = GitRunner()

        func makeRepo(_ name: String) async throws -> URL {
            let url = ws.appendingPathComponent(name)
            try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
            return url
        }

        _ = try await makeRepo("api")
        try "changed\n".write(to: ws.appendingPathComponent("api/README.md"), atomically: true, encoding: .utf8)

        _ = try await makeRepo("worker")
        try "changed\n".write(to: ws.appendingPathComponent("worker/README.md"), atomically: true, encoding: .utf8)

        let schedulerURL = try await makeRepo("scheduler")
        let remote = ws.deletingLastPathComponent().appendingPathComponent("scheduler-remote-\(UUID().uuidString).git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: schedulerURL)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: schedulerURL)
        let schedulerStore = RepositoryStore(url: schedulerURL)
        _ = await schedulerStore.push()
        try "second\n".write(to: schedulerURL.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        await schedulerStore.stageAll()
        _ = await schedulerStore.commit(CommitMessage(title: "second"))

        _ = try await makeRepo("frontend")
        _ = try await makeRepo("docs")
        _ = try await makeRepo("infra")

        if withRebase {
            let url = try await makeRepo("billing")
            _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
            try "feature\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try await git.run(["commit", "-q", "-am", "feature"], in: url)
            _ = try await git.run(["checkout", "-q", "master"], in: url)
            try "master\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try await git.run(["commit", "-q", "-am", "master"], in: url)
            _ = try await git.run(["checkout", "-q", "feature"], in: url)
            _ = try? await git.run(["rebase", "-q", "master"], in: url, allowedExitCodes: [0, 1])
        }

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-sidebar-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: ws)
        workspace.setTags(["work"], for: workspace.repositories.first { $0.repo.name == "frontend" }!)
        workspace.setTags(["work"], for: workspace.repositories.first { $0.repo.name == "docs" }!)
        await workspace.refreshAll()
        return workspace
    }

    private func render(_ view: some View, name: String, dark: Bool = false, size: CGSize = CGSize(width: 260, height: 480)) async throws -> String {
        try await renderHostedPNG(view, name: name, size: size, appearance: dark ? .darkAqua : nil, ticks: 15)
    }

    func testRender_allScope() async throws {
        let workspace = try await makeFixtureWorkspace()
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "30-sidebar-all")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    func testRender_changedScope() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.scope = .changed
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "31-sidebar-changed")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    func testRender_tagScope() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.scope = .tag("work")
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "32-sidebar-tag")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    func testRender_query() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.searchQuery = "api"
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "33-sidebar-query")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    /// `api` intensive (bolt glyph), `infra` paused (pause glyph) in the caption row.
    func testRender_fetchCadenceGlyphs() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.stopWatching()
        func repo(_ name: String) -> RepositoryStore { workspace.repositories.first { $0.repo.name == name }! }
        workspace.setFetchCadence(.intensive, for: repo("api"))
        workspace.setFetchCadence(.paused, for: repo("infra"))
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "37-sidebar-fetch-cadence")
        print("Rendered: \(path)")
    }

    /// Repo options sheet with custom agent patterns on and auto-fetch set to Intensive.
    func testRender_tagEditorAgentsAndCadence() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.stopWatching()
        let api = workspace.repositories.first { $0.repo.name == "api" }!
        workspace.setAgentPatterns(["bot@ci.example", "/^agent-\\d+/"], for: api)
        workspace.setFetchCadence(.intensive, for: api)
        let sheet = TagEditorSheet(store: api, workspace: workspace).background(Color(nsColor: .windowBackgroundColor))
        let path = try await render(sheet, name: "38-tag-editor-agents-cadence",
                                    size: CGSize(width: 420, height: 560))
        print("Rendered: \(path)")
    }

    /// Repo options sheet listing files excluded from secret scans, each with a remove button.
    func testRender_tagEditorSecretScanIgnored() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.stopWatching()
        let api = workspace.repositories.first { $0.repo.name == "api" }!
        workspace.ignoreSecretScan(["Tests/SecretScannerTests.swift", "Tests/Fixtures/deploy.pem"], for: api)
        let sheet = TagEditorSheet(store: api, workspace: workspace).background(Color(nsColor: .windowBackgroundColor))
        let path = try await render(sheet, name: "39-tag-editor-secret-ignored",
                                    size: CGSize(width: 420, height: 600))
        print("Rendered: \(path)")
    }

    func testRender_rebaseInProgress() async throws {
        let workspace = try await makeFixtureWorkspace(withRebase: true)
        XCTAssertEqual(workspace.repositories.first { $0.repo.name == "billing" }?.operation, .rebase)
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "35-sidebar-rebase")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    /// "Recent activity" sort: `api` and `worker` change after `infra` was selected, so both get the
    /// unread dot and a relative time; `api`'s is backdated to show a non-"just now" caption.
    func testRender_recentActivityAndUnseenDot() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.stopWatching()
        workspace.sort = .recent
        func repo(_ name: String) -> RepositoryStore { workspace.repositories.first { $0.repo.name == name }! }
        workspace.select(repo("infra"))
        for name in ["api", "worker"] {
            try "again\n".write(to: repo(name).url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            await repo(name).refreshStatus()
        }
        repo("api").lastActivity = Date().addingTimeInterval(-180)
        XCTAssertTrue(repo("api").hasUnseenChanges)
        XCTAssertEqual(workspace.visibleRepositories.prefix(2).map(\.repo.name), ["worker", "api"])
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "36-sidebar-recent-unseen")
        print("Rendered: \(path)")
    }

    /// `frontend` with two linked worktrees inside it (`.claude/worktrees/{fix-a,fix-b}`, where agents
    /// put them): both rows render indented right under `frontend`, with the branch glyph.
    func testRender_worktreesNested() async throws {
        let workspace = try await makeFixtureWorkspace()
        workspace.stopWatching()
        let frontend = workspace.repositories.first { $0.repo.name == "frontend" }!
        for name in ["fix-a", "fix-b"] {
            let path = frontend.url.appendingPathComponent(".claude/worktrees/\(name)").path
            _ = try await GitRunner().run(["worktree", "add", "-q", "-b", name, path], in: frontend.url)
        }
        await workspace.refreshAll()
        let order = WorkspaceStore.sidebarOrder(workspace.visibleRepositories)
        let i = try XCTUnwrap(order.firstIndex { $0.repo === frontend })
        XCTAssertEqual(order[(i + 1)...].prefix(2).map(\.repo.repo.name), ["fix-a", "fix-b"])
        XCTAssertEqual(order[(i + 1)...].prefix(2).map(\.depth), [1, 1])
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "37-sidebar-worktrees", size: CGSize(width: 260, height: 560))
        print("Rendered: \(path)")
    }

    func testRender_dark() async throws {
        let workspace = try await makeFixtureWorkspace()
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "34-sidebar-dark", dark: true)
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    /// ⌘ held: faint 1…n row indices at each row's top-trailing corner (⌘1…⌘9 targets).
    func testRender_commandIndices() async throws {
        let workspace = try await makeFixtureWorkspace()
        let view = SidebarView(workspace: workspace, showIndices: true).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "38-sidebar-cmd-indices")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    private func makeEmptyWorkspace() async -> WorkspaceStore {
        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-sidebar-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled()
        return workspace
    }

    /// One present repo (`present`) plus one single repo whose folder was deleted (`gone`) — the
    /// latter must stay listed, greyed, captioned "Missing".
    func testRender_missingRepo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-missing-render-\(UUID().uuidString)")
        let git = GitRunner()
        var urls: [URL] = []
        for name in ["present", "gone"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try await git.run(["init", "-q", "-b", "master"], in: url)
            urls.append(url)
        }
        let workspace = await makeEmptyWorkspace()
        for url in urls { try await workspace.addRepository(url) }
        try FileManager.default.removeItem(at: urls[1])
        await workspace.refreshAll()
        XCTAssertEqual(workspace.missingPaths.count, 1)
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
        let path = try await render(view, name: "sidebar-missing")
        print("Rendered: \(path)")
        workspace.stopWatching()
    }

    func testRender_emptyWorkspace() async throws {
        let workspace = await makeEmptyWorkspace()
        let view = SidebarView(workspace: workspace, openWorkspace: {}, openRecent: { _ in })
            .environment(ToastCenter()).environment(RemoteOpsCoordinator())
        // 200 pt: the sidebar's minimum width, where the old centred placeholder wrapped word by word.
        let path = try await render(view, name: "sidebar-empty-workspace", size: CGSize(width: 200, height: 420))
        print("Rendered: \(path)")
        workspace.stopWatching()
    }
}
