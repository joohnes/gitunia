import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for item 2: the flat/tree toggle used to live as a window
/// toolbar item, competing with the branch menu, Fetch/Pull/Push, stash, Stage All and the diff
/// controls — easy to lose in the `»` overflow or misread as a bare folder icon. It now lives in
/// the list's own header, next to the filter field.
///
/// The first version of this test hosted `ChangesView` in a bare `NSHostingView` with no window,
/// the same way `CommandPaletteRenderTests`'s pure-SwiftUI content renders fine offscreen. The
/// resulting PNGs showed the "Untracked (3)" section header with nothing underneath. Investigated
/// with a debug dump of the real `NSView` hierarchy (not shown here, done ad hoc) which found the
/// `List`'s `ListTableRowView`/`ListTableCellView`/`CellHostingView` rows *were* actually built,
/// at the correct frames, inside the scroll view's document view — so this was never a filtering
/// or collapsed-section bug in `ChangesView`, `ChangeSelection`, or the `FileTree.renderID` change.
/// The difference from `CommitDiffTreeRenderTests` (whose `List` rendered fine via the same
/// `cacheDisplay:` call) is that that test hosts its view inside a real (if offscreen-positioned)
/// `NSWindow` via `window.contentView = hosting`, while this test's original `render(_:name:)`
/// helper never attached a window at all. `NSTableView`'s row content — which is what backs
/// `List` on macOS — apparently needs to belong to a real window to actually composite for a
/// `cacheDisplay:` snapshot; pure-SwiftUI `Text`/`VStack` content (the palette's rows) has no such
/// requirement. Fixed by giving this harness the same real-offscreen-window treatment.
///
/// Disabled by default, same env var as `CommandPaletteRenderTests`:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter ChangesViewRenderTests
@MainActor
final class ChangesViewRenderTests: RenderTestCase {
    /// Staged, modified, and untracked files, some under nested directories that share a prefix
    /// (`db/migration`) and some standalone (`README.md`) — enough to show every section and, in
    /// tree mode, both a collapsed directory chain (`db/migration`) and a single-file directory.
    private func makeRepoWithMixedChanges() async throws -> (WorkspaceStore, RepositoryStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-changes-render-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, commit: false)

        func write(_ path: String, _ text: String) throws {
            let url = repoURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("README.md", "hello\n")
        try write("db/migration/V1.sql", "-- v1\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await git.run(["commit", "-q", "-m", "init"], in: repoURL)

        // Staged: a new migration file, added to the index.
        try write("db/migration/V2.sql", "-- v2\n")
        _ = try await git.run(["add", "db/migration/V2.sql"], in: repoURL)

        // Modified (unstaged): edit the already-committed README.
        try write("README.md", "hello\nmodified\n")

        // Untracked: a new file under a directory not seen before.
        try write("internal/app/deps.go", "package app\n")

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-changes-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else {
            throw XCTSkip("Repository did not scan into the workspace.")
        }
        await repo.refreshStatus()
        return (workspace, repo)
    }

    private func render(_ view: some View, name: String, size: CGSize = CGSize(width: 340, height: 620)) async throws -> String {
        try await renderHostedPNG(view, name: name, size: size, ticks: 15)
    }

    /// The header toggle is `@AppStorage("changesView.treeMode")`-backed, so simplest way to
    /// render both states is to set the default before constructing the view.
    func testRender_flatModeRows() async throws {
        UserDefaults.standard.set(false, forKey: "changesView.treeMode")
        let (workspace, repo) = try await makeRepoWithMixedChanges()
        var selectedChange: FileChange?
        let binding = Binding<FileChange?>(get: { selectedChange }, set: { selectedChange = $0 })
        let view = ChangesView(workspace: workspace, repo: repo, selectedChange: binding)
            .environment(ToastCenter()).environment(EditorOpenCoordinator())
        let path = try await render(view, name: "15-changes-flat-rows")
        print("Rendered: \(path)")
    }

    /// Two lockfiles folded under the collapsed "Lockfiles (2)" header at the bottom of Untracked,
    /// plus a 2 MB file whose row shows its size label, and an LFS-tracked `.psd` with its tag.
    func testRender_flatModeLockfilesAndSize() async throws {
        UserDefaults.standard.set(false, forKey: "changesView.treeMode")
        let (workspace, repo) = try await makeRepoWithMixedChanges()
        try "*.psd filter=lfs diff=lfs merge=lfs -text\n".write(to: repo.url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "psd".write(to: repo.url.appendingPathComponent("cover.psd"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: repo.url.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("ios"), withIntermediateDirectories: true)
        try "PODS:\n".write(to: repo.url.appendingPathComponent("ios/Podfile.lock"), atomically: true, encoding: .utf8)
        try Data(count: 2_000_000).write(to: repo.url.appendingPathComponent("big.bin"))
        await repo.refreshStatus()
        XCTAssertEqual(repo.untrackedChanges.first { $0.path == "big.bin" }?.size, 2_000_000)
        var selectedChange: FileChange?
        let binding = Binding<FileChange?>(get: { selectedChange }, set: { selectedChange = $0 })
        let view = ChangesView(workspace: workspace, repo: repo, selectedChange: binding)
            .environment(ToastCenter()).environment(EditorOpenCoordinator())
        let path = try await render(view, name: "18-changes-flat-lockfiles-size")
        print("Rendered: \(path)")
    }

    func testRender_treeModeRows() async throws {
        UserDefaults.standard.set(true, forKey: "changesView.treeMode")
        let (workspace, repo) = try await makeRepoWithMixedChanges()
        var selectedChange: FileChange?
        let binding = Binding<FileChange?>(get: { selectedChange }, set: { selectedChange = $0 })
        let view = ChangesView(workspace: workspace, repo: repo, selectedChange: binding)
            .environment(ToastCenter()).environment(EditorOpenCoordinator())
        let path = try await render(view, name: "16-changes-tree-rows")
        print("Rendered: \(path)")
        UserDefaults.standard.removeObject(forKey: "changesView.treeMode")
    }

    /// The commit box with a staged file — regression check after adding the secret-scan commit
    /// gate. The gate's `.confirmationDialog` never composites offscreen, so only the box renders.
    func testRender_CommitBoxWithStagedFile() async throws {
        let (workspace, repo) = try await makeRepoWithMixedChanges()
        XCTAssertFalse(repo.stagedChanges.isEmpty)
        let view = CommitBox(workspace: workspace, repo: repo)
            .environment(ToastCenter())
            .environment(RemoteOpsCoordinator())
            .padding(12)
        let path = try await render(view, name: "17-commitbox-staged", size: CGSize(width: 380, height: 220))
        print("Rendered: \(path)")
    }

    /// The "Committing as Name <email>" caption (with the signature glyph when signing is on) —
    /// only shown once `identity` is loaded, which ContentView does on selection.
    func testRender_CommitBoxIdentityCaption() async throws {
        let (workspace, repo) = try await makeRepoWithMixedChanges()
        _ = try await GitRunner().run(["config", "commit.gpgsign", "true"], in: repo.url)
        await repo.refreshIdentity()
        XCTAssertEqual(repo.identity?.email, "test@example.com")
        let view = CommitBox(workspace: workspace, repo: repo)
            .environment(ToastCenter())
            .environment(RemoteOpsCoordinator())
            .padding(12)
        let path = try await render(view, name: "18-commitbox-identity", size: CGSize(width: 380, height: 240))
        print("Rendered: \(path)")
    }

    /// Amend seeds from a HEAD whose body ends in a Claude trailer → it's stripped and the
    /// "Removed 1 agent trailer · Undo" note appears. HEAD is rewritten with commit-tree so the
    /// staged file stays staged. The checkbox can't be clicked in this harness (SwiftUI's checkbox
    /// has no target/action and ignores performClick/AX press), hence `amendOnAppear`.
    func testRender_CommitBoxAmendStripsTrailer() async throws {
        let (workspace, repo) = try await makeRepoWithMixedChanges()
        let git = GitRunner()
        let tree = try await git.run(["rev-parse", "HEAD^{tree}"], in: repo.url).trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = try await git.run(["commit-tree", tree, "-p", "HEAD", "-m", "feat: add login",
                                     "-m", "Adds the form.\n\nCo-Authored-By: Claude <noreply@anthropic.com>"], in: repo.url)
        _ = try await git.run(["update-ref", "HEAD", sha.trimmingCharacters(in: .whitespacesAndNewlines)], in: repo.url)
        await repo.refreshStatus()
        let view = CommitBox(workspace: workspace, repo: repo, amendOnAppear: true)
            .environment(ToastCenter())
            .environment(RemoteOpsCoordinator())
            .padding(12)
        let path = try await render(view, name: "19-commitbox-amend-trailer", size: CGSize(width: 380, height: 240))
        print("Rendered: \(path)")
    }
}
