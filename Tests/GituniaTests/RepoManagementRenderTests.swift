import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen renders of the repository-management UI (clone/new sheets, submodules, worktrees,
/// sidebar indicator + empty state) against real temp repositories. Same real-offscreen-window
/// technique as `SidebarHeaderRenderTests`. Opt-in:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter RepoManagementRenderTests
@MainActor
final class RepoManagementRenderTests: RenderTestCase {
    private let git = GitRunner()

    private func tempDir(_ tag: String) throws -> URL {
        try TestRepo.fixedRoot("repos-\(tag)")
    }

    private var commitOffset: TimeInterval = 0
    private func commitAll(_ url: URL, _ message: String) async throws {
        _ = try await git.run(["add", "-A"], in: url)
        commitOffset += 3600
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", message], date: TestRepo.fixedDate.addingTimeInterval(commitOffset), user: "T", email: "t@e")
    }

    private func makeRepo(_ url: URL, file: String = "README.md") async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await git.run(["init", "-q", "-b", "master"], in: url)
        _ = try await git.run(["config", "commit.gpgsign", "false"], in: url)
        try "hello\n".write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await commitAll(url, "init")
    }

    private func openWorkspace(_ ws: URL) async throws -> WorkspaceStore {
        let config = try tempDir("config").appendingPathComponent("config.json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: config))
        await workspace.openUntitled(linkingFolder: ws)
        return workspace
    }

    /// Workspace with `app` (+ sibling worktree `app-feature`, nested detached agent worktree,
    /// a locked one and a deleted/prunable one) and `super` with three submodules: current,
    /// moved to another commit (+), and deinitialized (-).
    private func makeFixture() async throws -> (WorkspaceStore, URL) {
        let ws = try tempDir("ws")
        let app = ws.appendingPathComponent("app")
        try await makeRepo(app)
        _ = try await git.run(["worktree", "add", "-q", "../app-feature", "-b", "feature/login"], in: app)
        _ = try await git.run(["worktree", "add", "-q", "--detach", ".claude/worktrees/agent-1"], in: app)
        _ = try await git.run(["worktree", "add", "-q", "../app-agent-2", "-b", "agent-2"], in: app)
        _ = try await git.run(["worktree", "lock", "--reason", "agent running", "../app-agent-2"], in: app)
        _ = try await git.run(["worktree", "add", "-q", "../app-old", "-b", "old"], in: app)
        try FileManager.default.removeItem(at: ws.appendingPathComponent("app-old"))

        let lib = try tempDir("lib")
        try await makeRepo(lib, file: "lib.txt")
        let sup = ws.appendingPathComponent("super")
        try await makeRepo(sup)
        for name in ["vendor-core", "vendor-ui", "vendor-docs"] {
            _ = try await git.run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.path, "libs/\(name)"], in: sup)
        }
        try await commitAll(sup, "add submodules")
        try "more\n".write(to: lib.appendingPathComponent("lib.txt"), atomically: true, encoding: .utf8)
        try await commitAll(lib, "more")
        let ui = sup.appendingPathComponent("libs/vendor-ui")
        _ = try await git.run(["fetch", "-q", "origin"], in: ui)
        _ = try await git.run(["checkout", "-q", "origin/master"], in: ui)
        _ = try await git.run(["submodule", "deinit", "-q", "libs/vendor-docs"], in: sup)

        let workspace = try await openWorkspace(ws)
        return (workspace, ws)
    }

    private func render(_ view: some View, name: String, size: CGSize, dark: Bool = false) async throws {
        let path = try await renderHostedPNG(view, name: name, size: size, appearance: dark ? .darkAqua : nil,
                                             activate: false, ticks: 15)
        print("Rendered: \(path)")
    }

    private func background(_ view: some View) -> some View {
        view.background(Color(nsColor: .windowBackgroundColor)).environment(ToastCenter())
    }

    func testRender_cloneProgress() async throws {
        let ws = try tempDir("ws")
        let workspace = try await openWorkspace(ws)
        defer { workspace.stopWatching() }
        let view = CloneRepositorySheet(workspace: workspace, url: "https://github.com/joohnes/monozu-api.git",
                                        progress: CloneProgress(phase: "Receiving objects", percent: 45), parent: ws)
        try await render(background(view), name: "repos-01-clone-progress", size: CGSize(width: 460, height: 280))
    }

    func testRender_cloneError() async throws {
        let ws = try tempDir("ws")
        let workspace = try await openWorkspace(ws)
        defer { workspace.stopWatching() }
        do {
            try await workspace.cloneRepository(from: "https://bot:s3cret@127.0.0.1:1/x.git", named: "x", in: ws)
            XCTFail("expected failure")
        } catch let e as GitError {
            let view = CloneRepositorySheet(workspace: workspace, url: "https://bot:s3cret@127.0.0.1:1/x.git",
                                            error: e.stderr.trimmingCharacters(in: .whitespacesAndNewlines), parent: ws)
            try await render(background(view), name: "repos-02-clone-error", size: CGSize(width: 460, height: 330))
        }
    }

    func testRender_newRepositoryTakenName() async throws {
        let ws = try tempDir("ws")
        try await makeRepo(ws.appendingPathComponent("api"))
        let workspace = try await openWorkspace(ws)
        defer { workspace.stopWatching() }
        try await render(background(NewRepositorySheet(workspace: workspace, name: "api", parent: ws)),
                         name: "repos-03-new-repo-taken", size: CGSize(width: 420, height: 240))
    }

    func testRender_submodules() async throws {
        let (workspace, ws) = try await makeFixture()
        defer { workspace.stopWatching() }
        let store = try XCTUnwrap(workspace.repository(atPath: ws.appendingPathComponent("super").path))
        await store.refreshSubmodules()
        XCTAssertEqual(store.submodules.map(\.state), [.current, .uninitialized, .outOfDate], "sorted by path: core, docs, ui")
        let ui = store.submodules[2]
        XCTAssertNotNil(ui.url)
        XCTAssertNotEqual(ui.recordedCommit, ui.checkedOutCommit, "vendor-ui drifted: recorded 'init' → checked out 'more'")
        try await render(background(SubmodulesSheet(store: store, workspace: workspace)),
                         name: "repos-04-submodules", size: CGSize(width: 560, height: 340))
    }

    func testRender_worktrees() async throws {
        let (workspace, ws) = try await makeFixture()
        defer { workspace.stopWatching() }
        let store = try XCTUnwrap(workspace.repository(atPath: ws.appendingPathComponent("app").path))
        let wts = try await store.worktrees()
        XCTAssertEqual(wts.count, 5)
        try await render(background(WorktreesSheet(store: store, workspace: workspace, worktrees: wts)),
                         name: "repos-05-worktrees", size: CGSize(width: 540, height: 360))
        try await render(background(WorktreesSheet(store: store, workspace: workspace, worktrees: wts)),
                         name: "repos-06-worktrees-dark", size: CGSize(width: 540, height: 360), dark: true)
    }

    /// Main + one linked worktree: "Add Worktree…" and the linked row's "Remove…" (none for master),
    /// no "Prune" since nothing is prunable. `repos-05` above (with the missing `app-old`) shows Prune.
    func testRender_worktreesTwoWithManagementControls() async throws {
        let ws = try tempDir("ws")
        let app = ws.appendingPathComponent("app")
        try await makeRepo(app)
        _ = try await git.run(["worktree", "add", "-q", "../app-feature", "-b", "feature/login"], in: app)
        let workspace = try await openWorkspace(ws)
        defer { workspace.stopWatching() }
        let store = try XCTUnwrap(workspace.repository(atPath: app.path))
        let wts = try await store.worktrees()
        XCTAssertEqual(wts.count, 2)
        try await render(background(WorktreesSheet(store: store, workspace: workspace, worktrees: wts)),
                         name: "repos-05b-worktrees-two", size: CGSize(width: 540, height: 220))
    }

    func testRender_sidebarWithWorktreesAndSubmoduleIndicator() async throws {
        let (workspace, _) = try await makeFixture()
        defer { workspace.stopWatching() }
        XCTAssertEqual(workspace.repositories.map(\.repo.name).sorted(), ["agent-1", "app", "app-agent-2", "app-feature", "super"])
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
            .environment(RepoSheets())
        try await render(view, name: "repos-07-sidebar", size: CGSize(width: 260, height: 400))
    }

    func testRender_sidebarEmptyState() async throws {
        let workspace = try await openWorkspace(try tempDir("empty"))
        defer { workspace.stopWatching() }
        let view = SidebarView(workspace: workspace).environment(ToastCenter()).environment(RemoteOpsCoordinator())
            .environment(RepoSheets())
        try await render(view, name: "repos-08-sidebar-empty", size: CGSize(width: 260, height: 400))
    }
}
