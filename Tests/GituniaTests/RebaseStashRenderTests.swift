import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen renders of the rebase/stash UI against real temp repos, in a real offscreen
/// `NSWindow` (needed for `List` rows to composite — see `ChangesViewRenderTests`).
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter RebaseStashRenderTests
@MainActor
final class RebaseStashRenderTests: RenderTestCase {
    private let git = GitRunner()

    private func makeWorkspace() async throws -> (WorkspaceStore, RepositoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-rebasestash-render-\(UUID().uuidString)")
        let url = root.appendingPathComponent("Backend")
        try await TestRepo.make(at: url, files: ["README.md": "hello\n", "api/handler.go": "package api\n\nfunc Handle() {}\n"])
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-rebasestash-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: config))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else { throw XCTSkip("Repository did not scan into the workspace.") }
        await repo.refreshStatus()
        return (workspace, repo, url)
    }

    private func write(_ repo: URL, _ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func render(_ view: some View, name: String, size: CGSize, dark: Bool = false) async throws {
        let root = view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)) // a sheet/window supplies this in the app
            .environment(ToastCenter()).environment(EditorOpenCoordinator())
            .preferredColorScheme(dark ? .dark : .light)
        let path = try await renderHostedPNG(root, name: "rebasestash-\(name)", size: size, appearance: dark ? .darkAqua : .aqua)
        print("Rendered: \(path)")
    }

    /// Two entries; the selected one has a tracked edit plus an untracked file (shown via
    /// `--include-untracked`), so the file list and diff both appear.
    private func makeStashes() async throws -> RepositoryStore {
        let (_, repo, url) = try await makeWorkspace()
        try write(url, "README.md", "hello\nolder stash\n")
        _ = await repo.stash(message: "spike: try other readme")
        try write(url, "api/handler.go", "package api\n\nfunc Handle() {\n\tlog.Println(\"hit\")\n}\n")
        try write(url, "api/handler_test.go", "package api\n\nfunc TestHandle(t *testing.T) {}\n")
        _ = await repo.stash(message: "agent WIP: logging in handler")
        return repo
    }

    func testRender_stashesSheet() async throws {
        let repo = try await makeStashes()
        var selection: StashItem.ID?
        let sheet = StashesSheet(repo: repo, selection: Binding(get: { selection }, set: { selection = $0 }))
        try await render(sheet, name: "01-stashes-sheet", size: CGSize(width: 900, height: 520))
    }

    func testRender_stashesSheetDark() async throws {
        let repo = try await makeStashes()
        var selection: StashItem.ID?
        let sheet = StashesSheet(repo: repo, selection: Binding(get: { selection }, set: { selection = $0 }))
        try await render(sheet, name: "02-stashes-sheet-dark", size: CGSize(width: 900, height: 520), dark: true)
    }

    /// The action row with the new `StashMenu` in place of the old inline menu, at the content
    /// column's 280pt minimum — the icon must not clip.
    func testRender_actionRowWithStashMenu() async throws {
        let (_, repo, url) = try await makeWorkspace()
        try write(url, "notes.txt", "x\n")
        await repo.refreshStatus()
        _ = await repo.stash(message: "one")
        try write(url, "README.md", "hello\nedit\n")
        await repo.refreshStatus()
        let row = ContentActionRow(repo: repo, contentMode: .constant(.changes), onDiscardAllRequested: {}, onUndoRequested: {}, onCleanUntrackedRequested: {})
        try await render(row, name: "03-actionrow-280", size: CGSize(width: 280, height: 44))
    }

    /// What Changes shows right after a pop that conflicted: the file under Conflicts, no
    /// operation banner (git writes no operation file for a stash conflict), no success claim.
    func testRender_changesAfterConflictingPop() async throws {
        let (workspace, repo, url) = try await makeWorkspace()
        try write(url, "README.md", "stashed\n")
        _ = await repo.stash(message: "one")
        try write(url, "README.md", "committed\n")
        _ = try await git.run(["commit", "-q", "-am", "c2"], in: url)
        await repo.refreshStatus()
        let outcome = await repo.stashApply((await repo.stashItems())[0], pop: true)
        XCTAssertEqual(outcome, .conflicts(1))
        var selected: FileChange?
        let view = ChangesView(workspace: workspace, repo: repo, selectedChange: Binding(get: { selected }, set: { selected = $0 }))
        try await render(view, name: "04-changes-after-conflicting-pop", size: CGSize(width: 340, height: 420))
    }

    /// A rebase-onto that stopped on conflicts lands in the existing operation banner.
    func testRender_changesAfterConflictingRebase() async throws {
        let (workspace, repo, url) = try await makeWorkspace()
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        try write(url, "README.md", "feature\n")
        _ = try await git.run(["commit", "-q", "-am", "feat"], in: url)
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        try write(url, "README.md", "master\n")
        _ = try await git.run(["commit", "-q", "-am", "master"], in: url)
        _ = try await git.run(["checkout", "-q", "feature"], in: url)
        await repo.refreshStatus()
        let outcome = await repo.rebase(onto: "master")
        XCTAssertEqual(outcome, .stoppedOnConflicts)
        var selected: FileChange?
        let view = ChangesView(workspace: workspace, repo: repo, selectedChange: Binding(get: { selected }, set: { selected = $0 }))
        try await render(view, name: "05-changes-after-conflicting-rebase", size: CGSize(width: 340, height: 420))
    }
}
