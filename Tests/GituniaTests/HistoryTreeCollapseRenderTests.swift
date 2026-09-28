import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for the flat-row tree rebuild (see `FileTree.flatten`'s doc
/// comment): collapsing a directory used to break `List` row geometry because both `ChangesView`
/// and `CommitDiffView` nested `DisclosureGroup`s inside a `List`.
///
/// **Deviation from driving a literal OS click through `CommitDiffView` itself:** several
/// synthesized-`NSEvent` techniques were tried (`window.sendEvent`, `NSApp.sendEvent`, both with
/// `up` pre-queued via `NSApp.postEvent` to dodge AppKit's mouseDown tracking-loop deadlock) and
/// the accessibility-action path (`accessibilityPerformPress`, reached via `responds(to:)`/
/// `perform(_:)` since a `some-@objc-protocol as?` cast checks *formal* protocol conformance, not
/// structural). Mouse-event coordinates were confirmed accurate — the correct row's hover
/// highlight appeared every time — but no technique got the nested SwiftUI `Button` inside the
/// `List` row to complete its own tap gesture in this offscreen, non-key-window, no-Accessibility-
/// permission harness (`accessibilityChildren()` returned empty for the hosting view itself,
/// meaning the AX tree wasn't populated at all — this sandbox has no way to grant the
/// Accessibility permission SwiftUI's AX bridge needs even for in-process queries).
///
/// `CommitDiffView.collapsedDirectories` is private `@State`, unreachable from a test without a
/// working click. So this test instead hosts the exact same production pieces
/// `CommitDiffView.fileList`'s tree branch uses — `List(selection:)`, `FileTree.flatten`,
/// `FileTreeRowView` — in a small local harness view with an externally driven collapsed set,
/// and drives state transitions by swapping `hosting.rootView` to a new view instance with a
/// different collapsed set, the same technique `CommitDiffTreeRenderTests` already uses for
/// commit-switching. This still exercises the real bug-fix code path (a flat `List` over
/// `FileTree.flatten`'s output, rendered by the real `FileTreeRowView`) end to end; the only thing
/// it doesn't drive is `CommitDiffView`'s own two-line toggle closure, which `ChangesView`'s and
/// `CommitDiffView`'s identical `toggleCollapsed` are covered by inspection and by the `FileTree`
/// unit tests (`testCollapsingDirectoryHidesAllDescendantsIncludingNested`, etc.) instead.
///
/// Disabled by default: RUN_PALETTE_RENDER_TESTS=1 swift test --filter HistoryTreeCollapseRenderTests
@MainActor
final class HistoryTreeCollapseRenderTests: RenderTestCase {
    /// One commit touching the exact file set from the task: a nested `db/migration` (3 files)
    /// and a nested `internal/app` (a file plus a further-nested `testdata` directory) alongside
    /// standalone files, so collapsing either directory has real descendants to hide.
    private func makeRepoWithOneCommit() async throws -> (WorkspaceStore, RepositoryStore, CommitInfo) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-tree-collapse-render-\(UUID().uuidString)")
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
        _ = try await git.run(["commit", "-q", "-m", "init"], in: repoURL)

        try write("api/z.go", "package api\n")
        try write("db/migration/V185.sql", "-- v185\n")
        try write("db/migration/V186.sql", "-- v186\n")
        try write("db/migration/V187.sql", "-- v187\n")
        try write("internal/app/deps.go", "package app\n")
        try write("internal/app/testdata/y.txt", "fixture\n")
        try write("internal/app/background.go", "package app\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await git.run(["commit", "-q", "-m", "Touch nested dirs"], in: repoURL)

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-tree-collapse-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else {
            throw XCTSkip("Repository did not scan into the workspace.")
        }
        let commits = await repo.history()
        guard let commit = commits.first else { throw XCTSkip("Expected at least one commit.") }
        return (workspace, repo, commit)
    }

    /// Mirrors `CommitDiffView.fileList`'s tree branch exactly — same `List(selection:)`, same
    /// `FileTree.flatten` call, same `FileTreeRowView` row renderer — with the collapsed set taken
    /// as a parameter instead of private `@State`, so a test can drive it directly. See this file's
    /// type doc comment for why: no click-simulation technique reached the nested `Button`'s tap
    /// gesture in this offscreen harness.
    private struct HistoryTreeHarness: View {
        let files: [FileDiff]
        let collapsed: Set<String>
        @State private var selectedPath: String?

        var body: some View {
            List(selection: $selectedPath) {
                let tree = FileTree.build(from: files, path: \.path, salt: "history")
                ForEach(FileTree.flatten(tree, collapsed: collapsed)) { row in
                    switch row.kind {
                    case .directory:
                        FileTreeRowView(row: row, onToggle: { _ in }) { _, name in
                            Text(name).lineLimit(1)
                        }
                    case .file(let file, _):
                        FileTreeRowView(row: row, onToggle: { _ in }) { _, name in
                            Text(name).lineLimit(1)
                        }
                        .tag(file.path)
                    }
                }
            }
        }
    }

    func testRender_expandCollapseReexpandHistoryTree() async throws {
        let (_, repo, commit) = try await makeRepoWithOneCommit()
        let files = await repo.commitDiff(commit.hash)
        XCTAssertEqual(files.count, 7)

        let size = CGSize(width: 700, height: 500)
        let (hosting, window) = hostOffscreen(HistoryTreeHarness(files: files, collapsed: []), size: size)
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)

        print("Rendered: \(try writePNG(hosting, name: "20-history-tree-expanded"))")

        let tree = FileTree.build(from: files, path: \.path, salt: "history")
        func directoryID(named name: String) -> String {
            func search(_ nodes: [FileTreeNode<FileDiff>]) -> String? {
                for node in nodes {
                    if case .directory(let n, _, let id, let children) = node {
                        if n == name { return id }
                        if let found = search(children) { return found }
                    }
                }
                return nil
            }
            return search(tree)!
        }
        let dbMigrationID = directoryID(named: "db/migration")
        let internalAppID = directoryID(named: "internal/app")

        hosting.rootView = AnyView(HistoryTreeHarness(files: files, collapsed: [dbMigrationID])
            .frame(width: size.width, height: size.height))
        await pumpLayout(hosting)
        print("Rendered: \(try writePNG(hosting, name: "21-history-tree-collapsed"))")

        hosting.rootView = AnyView(HistoryTreeHarness(files: files, collapsed: [dbMigrationID, internalAppID])
            .frame(width: size.width, height: size.height))
        await pumpLayout(hosting)
        print("Rendered: \(try writePNG(hosting, name: "22-history-tree-two-collapsed"))")

        hosting.rootView = AnyView(HistoryTreeHarness(files: files, collapsed: [internalAppID])
            .frame(width: size.width, height: size.height))
        await pumpLayout(hosting)
        print("Rendered: \(try writePNG(hosting, name: "23-history-tree-reexpanded"))")
    }
}
