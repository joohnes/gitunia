import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for spec items 3 (content-column action row) and 4 (Wrap as a
/// text toggle).
///
/// Same real-offscreen-window technique as `ChangesViewRenderTests`/`SidebarHeaderRenderTests` —
/// needed here too because `ContentActionRow`'s Stash `Menu` and the Wrap `Toggle` are AppKit
/// controls that don't composite for `cacheDisplay:` without a real (if offscreen-positioned)
/// `NSWindow`; see `ChangesViewRenderTests`'s type doc comment for how that was found.
///
/// Disabled by default, same env var as the other render harnesses:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter ActionRowRenderTests
@MainActor
final class ActionRowRenderTests: RenderTestCase {
    private func makeTempRepo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-actionrow-render-\(UUID().uuidString)")
        return try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
    }

    /// A repo with staged, unstaged and untracked changes — enough for every Changes-mode button
    /// in the row to be enabled at once.
    private func makeRepoWithMixedChanges() async throws -> RepositoryStore {
        let url = try await makeTempRepo()
        let git = GitRunner()
        try "staged\n".write(to: url.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "staged.txt"], in: url)
        try "hello\nmodified\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: url.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return store
    }

    /// A second commit on top of `makeTempRepo()`'s init commit, so `hasParentCommit` is true and
    /// "Undo Last Commit" renders enabled.
    private func makeRepoWithHistory() async throws -> RepositoryStore {
        let url = try await makeTempRepo()
        let git = GitRunner()
        try "second\n".write(to: url.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "second commit"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return store
    }

    private func render(_ view: some View, name: String, size: CGSize, colorScheme: ColorScheme = .light) async throws -> String {
        try await renderHostedPNG(view.preferredColorScheme(colorScheme), name: name, size: size,
                                  appearance: colorScheme == .dark ? .darkAqua : .aqua, ticks: 15)
    }

    private func renderToolbar(wrapOn: Bool, name: String, colorScheme: ColorScheme) async throws -> String {
        try await renderToolbarPNG(ToolbarFixture(wrap: wrapOn), name: name, size: CGSize(width: 900, height: 100),
                                   toolbar: "wrap-fixture", appearance: colorScheme == .dark ? .darkAqua : .aqua, ticks: 15)
    }

    func testRender_changesActionRow300() async throws {
        let repo = try await makeRepoWithMixedChanges()
        let row = ContentActionRow(repo: repo, contentMode: .constant(.changes), onDiscardAllRequested: {}, onUndoRequested: {}, onCleanUntrackedRequested: {})
        let path = try await render(row, name: "40-actionrow-changes-300", size: CGSize(width: 300, height: 44))
        print("Rendered: \(path)")
    }

    func testRender_changesActionRow400() async throws {
        let repo = try await makeRepoWithMixedChanges()
        let row = ContentActionRow(repo: repo, contentMode: .constant(.changes), onDiscardAllRequested: {}, onUndoRequested: {}, onCleanUntrackedRequested: {})
        let path = try await render(row, name: "41-actionrow-changes-400", size: CGSize(width: 400, height: 44))
        print("Rendered: \(path)")
    }

    func testRender_historyActionRow() async throws {
        let repo = try await makeRepoWithHistory()
        let row = ContentActionRow(repo: repo, contentMode: .constant(.history), onDiscardAllRequested: {}, onUndoRequested: {}, onCleanUntrackedRequested: {})
        let path = try await render(row, name: "42-actionrow-history", size: CGSize(width: 340, height: 44))
        print("Rendered: \(path)")
    }

    /// Standalone render of the Wrap control: `DiffView`'s own instance lives inside a `.toolbar`
    /// `ToolbarItem`, which (like the window toolbar items in other render tests) doesn't
    /// composite offscreen — so this renders the exact same `Toggle("Wrap", isOn:)
    /// .toggleStyle(.button).tint(.accentColor)` view code next to a stand-in `Inline | Split`
    /// segmented control, to compare their look directly.
    private func wrapToggleFixture(isOn: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("Diff mode", selection: .constant(0)) {
                Text("Inline").tag(0)
                Text("Split").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            WrapToggle(isOn: .constant(isOn))
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func testRender_wrapOff() async throws {
        let path = try await render(wrapToggleFixture(isOn: false), name: "43-wrap-off", size: CGSize(width: 260, height: 50))
        print("Rendered: \(path)")
    }

    func testRender_wrapOn() async throws {
        let path = try await render(wrapToggleFixture(isOn: true), name: "44-wrap-on", size: CGSize(width: 260, height: 50))
        print("Rendered: \(path)")
    }

    func testRender_wrapOnDark() async throws {
        let path = try await render(wrapToggleFixture(isOn: true), name: "45-wrap-on-dark", size: CGSize(width: 260, height: 50), colorScheme: .dark)
        print("Rendered: \(path)")
    }

    /// The real `WrapToggle`, in the same `.toolbar` placement as `DiffView` (next to a stand-in
    /// `Inline | Split` segmented control), hosted in a real titled/toolbar `NSWindow` so macOS 26
    /// draws its own bezel around the toolbar item — the thing the standalone `wrapToggleFixture`
    /// renders above can't show, since it's not inside a toolbar at all. Captures the window's
    /// theme frame (`contentView.superview`), not just `contentView`, because the toolbar itself
    /// lives in the theme frame.
    private struct ToolbarFixture: View {
        @State var wrap: Bool
        var body: some View {
            Color.clear
                .toolbar {
                    ToolbarItem {
                        Picker("Diff mode", selection: .constant(0)) {
                            Text("Inline").tag(0)
                            Text("Split").tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                    ToolbarItem {
                        WrapToggle(isOn: $wrap)
                    }
                }
        }
    }

    func testRender_wrapToolbarOffDark() async throws {
        let path = try await renderToolbar(wrapOn: false, name: "60-wrap-toolbar-off-dark", colorScheme: .dark)
        print("Rendered: \(path)")
    }

    func testRender_wrapToolbarOnDark() async throws {
        let path = try await renderToolbar(wrapOn: true, name: "61-wrap-toolbar-on-dark", colorScheme: .dark)
        print("Rendered: \(path)")
    }

    func testRender_wrapToolbarOffLight() async throws {
        let path = try await renderToolbar(wrapOn: false, name: "62-wrap-toolbar-off-light", colorScheme: .light)
        print("Rendered: \(path)")
    }

    func testRender_wrapToolbarOnLight() async throws {
        let path = try await renderToolbar(wrapOn: true, name: "63-wrap-toolbar-on-light", colorScheme: .light)
        print("Rendered: \(path)")
    }

    // MARK: - T4: clean-preview sheet and the action row's new trash button

    /// The real sheet content view rendered directly (a `.sheet` never composites offscreen — see
    /// this file's own type doc comment) with ~5 files including one directory, so the "list
    /// every file, scrollable, destructive delete button" layout can be checked by eye.
    func testRender_cleanPreviewSheet() async throws {
        let content = CleanPreviewSheetContent(
            includeDirectories: .constant(true),
            files: ["build/", ".DS_Store", "debug.log", "tmp/scratch.txt", "untracked.txt"],
            isLoading: false,
            onCancel: {},
            onDelete: {}
        )
        let path = try await render(content, name: "95-clean-preview", size: CGSize(width: 420, height: 340))
        print("Rendered: \(path)")
    }

    /// The action row with the new trash button alongside the other four Changes-mode icons, at
    /// the content column's 280pt minimum width — verifies the fifth icon and the stash menu don't clip.
    func testRender_actionRowWithClean() async throws {
        let repo = try await makeRepoWithMixedChanges() // has an untracked file, so the trash button is enabled
        let row = ContentActionRow(repo: repo, contentMode: .constant(.changes), onDiscardAllRequested: {}, onUndoRequested: {}, onCleanUntrackedRequested: {})
        let path = try await render(row, name: "96-actionrow-with-clean", size: CGSize(width: 280, height: 44))
        print("Rendered: \(path)")
    }

    /// Dark variant at the column minimum (folds into the overflow menu) and a wider row where all
    /// four icons fit: the stash `Menu` must look like its sibling buttons in both.
    func testRender_actionRowDarkAndNarrow() async throws {
        let repo = try await makeRepoWithMixedChanges()
        let row = ContentActionRow(repo: repo, contentMode: .constant(.changes), onDiscardAllRequested: {}, onUndoRequested: {}, onCleanUntrackedRequested: {})
        print("Rendered:", try await render(row, name: "97-actionrow-dark", size: CGSize(width: 280, height: 44), colorScheme: .dark))
        print("Rendered:", try await render(row, name: "98-actionrow-440", size: CGSize(width: 440, height: 44)))
    }
}
