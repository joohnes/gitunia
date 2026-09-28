import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for item 1: the user's screenshot showed a file row
/// (`V186__assets_lifecycle_dates.sql`) drawn on top of a directory row (`> internal`) inside
/// `CommitDiffView`'s file tree, right after switching commits. Same offscreen-`NSHostingView`
/// technique as `CommandPaletteRenderTests` (no Screen Recording permission needed).
///
/// Root cause (see `FileTree.renderID`'s doc comment): `FileTree` intentionally keeps a
/// directory's `id` stable across rebuilds (`"dir:<salt>:<path>"`) so expand/selection state
/// survives a refresh. But `CommitDiffView`'s tree salts with the constant `"history"`, not the
/// commit hash — so switching to a second commit that shares a directory path (`db/migration`,
/// `internal/app`) but has *different children under it* reuses the exact same `id` for a
/// structurally different row. `List` on macOS is `NSTableView`-backed and caches row height
/// against identity, so the cached height from commit A's shape gets reused for commit B's
/// differently-shaped subtree — rows overlap. The fix folds each directory's child shape into a
/// separate `renderID` used only for `ForEach`/`List` identity, forcing a fresh height
/// measurement whenever what's rendered under a directory actually changed, while `expandedBinding`
/// still keys off the stable `id` so disclosure state isn't lost.
///
/// Disabled by default, same env var as `CommandPaletteRenderTests`:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter CommitDiffTreeRenderTests
@MainActor
final class CommitDiffTreeRenderTests: RenderTestCase {
    /// Builds a real temp repo with two commits that share directory prefixes but differ in
    /// structure underneath them — exactly the shape the task describes: commit A touches
    /// `db/migration/V185.sql`, `db/migration/V186.sql`, `internal/app/x.go`; commit B touches
    /// `db/migration/V187.sql`, `internal/app/testdata/y.txt`, `internal/app/deps.go`, `api/z.go`.
    private func makeRepoWithTwoCommits() async throws -> (WorkspaceStore, RepositoryStore, [CommitInfo]) {
        let root = try TestRepo.fixedRoot("commit-diff-tree")
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

        // Commit A.
        try write("db/migration/V185.sql", "-- v185\n")
        try write("db/migration/V186__assets_lifecycle_dates.sql", "-- v186\n")
        try write("internal/app/x.go", "package app\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "Commit A: migrations and app"],
                                      date: TestRepo.fixedDate.addingTimeInterval(3600))

        // Commit B: same directory prefixes, different shape underneath.
        try write("db/migration/V187.sql", "-- v187\n")
        try write("internal/app/testdata/y.txt", "fixture\n")
        try write("internal/app/deps.go", "package app\n")
        try write("api/z.go", "package api\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "Commit B: more migrations, testdata, api"],
                                      date: TestRepo.fixedDate.addingTimeInterval(7200))

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-tree-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else {
            throw XCTSkip("Repository did not scan into the workspace.")
        }
        let commits = await repo.history()
        guard commits.count >= 2 else { throw XCTSkip("Expected at least two commits.") }
        return (workspace, repo, commits)
    }

    /// Drives the real bug scenario on one hosted `CommitDiffView` instance: render commit A's
    /// tree (all expanded by default), then swap `rootView` to commit B — the same transition
    /// `ContentView` performs when the user clicks a different commit in `HistoryView`, since both
    /// branches are the same `CommitDiffView` identity. Captures both states.
    func testRender_switchingCommitsWithSharedDirectoryPrefixes() async throws {
        let (workspace, repo, commits) = try await makeRepoWithTwoCommits()
        let toasts = ToastCenter()
        let editorRequests = EditorOpenCoordinator()
        // `history()` returns newest-first, so the newest is Commit B, previous is Commit A.
        let commitB = commits[0]
        let commitA = commits[1]
        XCTAssertTrue(commitB.subject.contains("Commit B"))
        XCTAssertTrue(commitA.subject.contains("Commit A"))

        var selectedPath: String?
        let selectedPathBinding = Binding<String?>(get: { selectedPath }, set: { selectedPath = $0 })

        let size = CGSize(width: 700, height: 500)
        let viewA = CommitDiffView(workspace: workspace, repo: repo, commit: commitA, selectedPath: selectedPathBinding, selection: .constant(commitA))
            .environment(toasts).environment(editorRequests)
            .frame(width: size.width, height: size.height)
        let (hosting, window) = hostOffscreen(viewA, size: size)
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)

        let beforePath = try writePNG(hosting, name: "09-commitA-tree")
        print("Rendered: \(beforePath)")

        // Swap to Commit B on the *same* hosted view — this is what reproduces the bug: the
        // directory rows for `db/migration` and `internal/app` keep the same stable `id` (salt is
        // the constant "history", not the commit hash) but now have a different shape underneath.
        let viewB = CommitDiffView(workspace: workspace, repo: repo, commit: commitB, selectedPath: selectedPathBinding, selection: .constant(commitB))
            .environment(toasts).environment(editorRequests)
            .frame(width: size.width, height: size.height)
        hosting.rootView = AnyView(viewB)
        await pumpLayout(hosting)

        let afterPath = try writePNG(hosting, name: "10-commitB-tree-after-switch")
        print("Rendered: \(afterPath)")
    }
}
