import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for the flat-row tree rebuild in `ChangesView`'s tree mode — the
/// other place `FileTree.flatten`/`FileTreeRowView` replaced a recursive `DisclosureGroup`-in-
/// `List` (see `FileTree.flatten`'s doc comment, and `HistoryTreeCollapseRenderTests` for the
/// `CommitDiffView` side). Same deviation as `HistoryTreeCollapseRenderTests`: `ChangesView`'s
/// `collapsedDirectories` is private `@State` unreachable without a working click, and no
/// synthesized-click technique reached the nested `Button` in this offscreen harness, so this
/// hosts the same production pieces (`List(selection:)`, `FileTree.build`, `FileTree.flatten`,
/// `FileTreeRowView`, `ChangeRow(showsPath: false)`) `ChangesView.treeSection`/`treeRow` use, with
/// the collapsed set taken as a parameter.
///
/// Disabled by default: RUN_PALETTE_RENDER_TESTS=1 swift test --filter ChangesTreeCollapseRenderTests
@MainActor
final class ChangesTreeCollapseRenderTests: RenderTestCase {
    private func change(_ path: String, status: FileChange.Status = .modified, area: FileChange.Area = .unstaged) -> FileChange {
        FileChange(path: path, status: status, area: area)
    }

    /// A nested fixture: `db/migration` with two files (a directory worth collapsing) plus a
    /// standalone `README.md`, all in one "Changes" section — enough to show both a real
    /// collapse and an unaffected sibling row.
    private var nestedChanges: [FileChange] {
        [
            change("README.md"),
            change("db/migration/V1.sql"),
            change("db/migration/V2.sql"),
        ]
    }

    private struct ChangesTreeHarness: View {
        let changes: [FileChange]
        let collapsed: Set<String>
        @State private var selection: Set<FileChange> = []

        var body: some View {
            List(selection: $selection) {
                Section("Changes (\(changes.count))") {
                    let tree = FileTree.build(from: changes, path: \.path, salt: "Changes")
                    ForEach(FileTree.flatten(tree, collapsed: collapsed)) { row in
                        switch row.kind {
                        case .directory:
                            FileTreeRowView(row: row, onToggle: { _ in }) { change, _ in
                                ChangeRow(change: change, showsPath: false)
                            }
                        case .file(let fileChange, _):
                            FileTreeRowView(row: row, onToggle: { _ in }) { change, _ in
                                ChangeRow(change: change, showsPath: false)
                            }
                            .tag(fileChange)
                        }
                    }
                }
            }
        }
    }

    func testRender_changesTreeExpandedAndCollapsed() async throws {
        let changes = nestedChanges
        let tree = FileTree.build(from: changes, path: \.path, salt: "Changes")
        guard case .directory(let name, _, let dbMigrationID, _) = tree.first(where: {
            if case .directory(let n, _, _, _) = $0 { return n == "db/migration" }
            return false
        })! else {
            return XCTFail("expected db/migration directory")
        }
        XCTAssertEqual(name, "db/migration")

        let size = CGSize(width: 340, height: 300)
        let (hosting, window) = hostOffscreen(ChangesTreeHarness(changes: changes, collapsed: []), size: size)
        defer { window.orderOut(nil) }
        await pumpLayout(hosting, ticks: 15)

        print("Rendered: \(try writePNG(hosting, name: "24-changes-tree"))")

        hosting.rootView = AnyView(ChangesTreeHarness(changes: changes, collapsed: [dbMigrationID])
            .frame(width: size.width, height: size.height))
        await pumpLayout(hosting, ticks: 15)
        print("Rendered: \(try writePNG(hosting, name: "25-changes-tree-collapsed"))")
    }
}
