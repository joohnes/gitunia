import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for the ⌘K palette bug: the user's screenshot with query "pull"
/// showed exactly one row, "Backend" (their alphabetically-first repo), and nothing else — no
/// matter what they typed. There is no Screen Recording permission in this environment, so a real
/// screenshot of the running app is impossible, but rendering the actual `CommandPalette` view
/// offscreen into an `NSHostingView` and reading back a bitmap needs no such permission.
///
/// Disabled by default (see `RUN` below) because it shells out to `git init` for five temp repos
/// and drives real SwiftUI layout, which is slower and marginally less deterministic than the rest
/// of the suite. Run explicitly with:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter CommandPaletteRenderTests
@MainActor
final class CommandPaletteRenderTests: RenderTestCase {
    /// Real temp git repos named like the user's, so `WorkspaceScanner` finds them exactly the way
    /// it would in production (no faking `RepositoryStore` internals).
    private func makeWorkspace(named names: [String]) async throws -> WorkspaceStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-palette-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for name in names {
            let repoURL = root.appendingPathComponent(name)
            let git = GitRunner()
            try await TestRepo.make(at: repoURL, files: ["README.md": "hello\n"])
            // Non-current branches, so the branch step (which hides the checked-out one) has rows.
            _ = try await git.run(["branch", "feature/login"], in: repoURL)
            _ = try await git.run(["branch", "fix/crash"], in: repoURL)
        }

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-palette-render-config-\(UUID().uuidString).json")
        let store = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await store.openUntitled(linkingFolder: root)
        return store
    }

    private func render(_ view: some View, name: String, size: CGSize = CGSize(width: 480, height: 420)) throws -> String {
        try renderPlainPNG(view, name: name, size: size)
    }

    private let repoNames = ["Backend", "Documentation", "Edge", "Frontend", "Infrastructure"]

    /// State 1: empty query — every action plus every repo, unfiltered.
    func testRender_emptyQuery() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        let toasts = ToastCenter()
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}, initialQuery: ""
        ).environment(toasts).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
        let path = try render(view, name: "01-empty-query")
        print("Rendered: \(path)")
    }

    /// State 2: the user's exact repro — query "pull" typed at the top level.
    func testRender_queryPull() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        let toasts = ToastCenter()
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}, initialQuery: "pull"
        ).environment(toasts).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
        let path = try render(view, name: "02-query-pull")
        print("Rendered: \(path)")

        // Cross-check against the pure row model directly: with this exact input, does "Backend"
        // (a) ever appear in the row list at all?
        let rows = PaletteRows.build(
            repositories: repoNames.map { PaletteRows.RepoEntry(id: $0, name: $0) },
            changeFilename: "",
            pending: nil,
            query: "pull"
        )
        let names = rows.compactMap { row -> String? in
            if case .repository(let e) = row { return e.name }
            return nil
        }
        XCTAssertFalse(names.contains("Backend"), "PaletteRows.build already excludes Backend for query 'pull' — if the render still shows it, the bug is in the view, not the row model.")
        XCTAssertTrue(rows.contains(.action(.pullSelected)), "Expected the Pull action row to match query 'pull'.")
    }

    /// NOT a render of the pending-Pull second step itself (chip + "All repositories" + repos) —
    /// that requires actually driving the Return keypress on an already-mounted instance, which
    /// `initialQuery` can't do (it only seeds a *fresh* view's starting state, and `pendingAction`
    /// has no equivalent seam by design — see `testRender_liveChipStepTransition` below, which
    /// drives the real transition and is the test that actually verifies this state visually).
    /// This test only re-renders the step *before* it (top-level query "pull") and cross-checks
    /// `PaletteRows.build`'s pending-query-cleared output directly against the pure model, as a
    /// belt-and-suspenders check independent of the view.
    func testPendingPullRowModel_matchesWhatReturnShouldProduce() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        let toasts = ToastCenter()
        let secondStepRows = PaletteRows.build(
            repositories: repoNames.map { PaletteRows.RepoEntry(id: $0, name: $0) },
            changeFilename: "",
            pending: .pullSelected,
            query: ""
        )
        XCTAssertEqual(secondStepRows.first, .allRepositories)
        XCTAssertEqual(secondStepRows.count, 1 + repoNames.count)

        // Render the step that leads into it, for the visual record.
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}, initialQuery: "pull"
        ).environment(toasts).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
        let path = try render(view, name: "03-before-pending-pull-step")
        print("Rendered: \(path)")
    }

    /// The critical check: `initialQuery` renders a *fresh* view whose `query` state is already
    /// "pull" from the start — it never exercises the transition a real user causes by typing into
    /// an already-mounted, already-populated palette. If the real bug were "the rows never
    /// re-render after the query changes on a live instance" (candidate cause (b), the
    /// LazyVStack/ScrollViewReader/double-identity issue), a static `initialQuery` render could
    /// look perfectly correct while the live app is still stuck — so this test drives the *same*
    /// hosted view instance by actually typing into its `NSTextField`, the same way a keystroke
    /// does in production, and re-captures.
    func testRender_liveTypingIntoAlreadyMountedPalette() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        let toasts = ToastCenter()
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}
        ).environment(toasts).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())

        let size = CGSize(width: 480, height: 420)
        // Needs a real (offscreen-positioned) window so the text field can become first responder —
        // an NSHostingView with no window never activates its NSTextView editor.
        let (hosting, window) = hostOffscreen(view, size: size)
        window.makeKey()
        defer { window.orderOut(nil) }

        func pump() { pumpRunLoop(hosting) }
        pump()

        func findTextField(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField { return tf }
            for sub in view.subviews {
                if let found = findTextField(in: sub) { return found }
            }
            return nil
        }
        guard let field = findTextField(in: hosting) else {
            throw XCTSkip("Could not locate the palette's NSTextField in the hosted view tree — cannot drive live typing offscreen.")
        }
        window.makeFirstResponder(field)
        pump()

        let before = try writePNG(hosting, name: "04-live-empty-before-typing")
        print("Rendered: \(before)")

        guard let editor = field.currentEditor() as? NSTextView else {
            throw XCTSkip("Text field has no NSTextView field editor after becoming first responder — cannot type offscreen.")
        }
        editor.insertText("pull", replacementRange: editor.selectedRange())
        pump()

        let after = try writePNG(hosting, name: "05-live-after-typing-pull")
        print("Rendered: \(after)")
    }

    /// Regression: choosing a repository at the top level (no action picked) must go to that
    /// repository. The two-step rework once made this row a silent no-op.
    @MainActor
    func testChoosingRepositoryAtTopLevelSelectsIt() async throws {
        let workspace = try await makeWorkspace(named: ["Backend", "Frontend"])
        final class Flag { var open = true }
        let flag = Flag()
        let presented = Binding(get: { flag.open }, set: { flag.open = $0 })
        let view = CommandPalette(workspace: workspace, isPresented: presented, openWorkspace: {})
            .environment(ToastCenter()).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
        let size = CGSize(width: 480, height: 420)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func pump() { pumpRunLoop(hosting) }
        pump()
        func findTextField(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField { return tf }
            for sub in view.subviews { if let f = findTextField(in: sub) { return f } }
            return nil
        }
        guard let field = findTextField(in: hosting) else { throw XCTSkip("No palette text field offscreen.") }
        window.makeFirstResponder(field)
        pump()
        guard let editor = field.currentEditor() as? NSTextView else { throw XCTSkip("No field editor offscreen.") }
        editor.insertText("fronte", replacementRange: editor.selectedRange())
        pump()
        sendKey(36, character: "\r", to: window)
        pump()

        let frontend = workspace.repositories.first { $0.repo.name == "Frontend" }
        XCTAssertEqual(workspace.selectedRepoID, frontend?.id, "Return on a repository row should select it.")
        XCTAssertFalse(flag.open, "Choosing a repository should close the palette.")
    }

    /// Drives the actual actions → repository-picker transition (the same class of bug just fixed:
    /// a list transition on an already-mounted view) through the real interaction path — no seam
    /// that pokes `pendingAction` directly. Sequence, all on one hosted instance:
    ///   1. type "pull"                         -> expect only the "Pull" action row
    ///   2. press Return (real key handling)     -> expect the pending state: Pull chip, empty
    ///                                              query, "All repositories" first, then all 5 repos
    ///   3. type "fro"                           -> expect "All repositories" + Frontend only
    ///   4. clear "fro" then press Backspace once more on an empty query (real key handling)
    ///                                            -> expect the chip gone, back to the top-level list
    /// Return/Backspace are dispatched as real `NSEvent`s via `sendKey` (see above), so this
    /// exercises `CommandPalette`'s actual `.onKeyPress(.return)` / `.onKeyPress(.delete)` handlers,
    /// not a test-only bypass. (Verified while writing this test: temporarily adding a `print` inside
    /// each handler in `CommandPalette.swift` confirmed both fire, with the expected `pendingAction`/
    /// `query` values at each step, before the prints were removed again.)
    func testRender_liveChipStepTransition() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        let toasts = ToastCenter()
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}
        ).environment(toasts).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())

        let size = CGSize(width: 480, height: 420)
        let (hosting, window) = hostOffscreen(view, size: size)
        window.makeKey()
        defer { window.orderOut(nil) }

        func pump() { pumpRunLoop(hosting) }
        pump()

        func findTextField(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField { return tf }
            for sub in view.subviews {
                if let found = findTextField(in: sub) { return found }
            }
            return nil
        }
        guard let field = findTextField(in: hosting) else {
            throw XCTSkip("Could not locate the palette's NSTextField in the hosted view tree — cannot drive live typing offscreen.")
        }
        window.makeFirstResponder(field)
        pump()

        guard let editor = field.currentEditor() as? NSTextView else {
            throw XCTSkip("Text field has no NSTextView field editor after becoming first responder — cannot drive key handling offscreen.")
        }

        // Step 1: type "pull".
        editor.insertText("pull", replacementRange: editor.selectedRange())
        pump()

        // Step 2: press Return (keyCode 36, "\r").
        sendKey(36, character: "\r", to: window)
        pump()
        let chipStep = try writePNG(hosting, name: "06-live-chip-step")
        print("Rendered: \(chipStep)")

        // Step 3: type "fro" — the field editor should still be valid/focused after the transition;
        // re-resolve it in case SwiftUI recreated the underlying NSTextField.
        guard let field2 = findTextField(in: hosting) else {
            throw XCTSkip("Could not relocate the palette's NSTextField after the chip transition.")
        }
        if window.firstResponder !== field2.currentEditor() { window.makeFirstResponder(field2) }
        pump()
        guard let editor2 = field2.currentEditor() as? NSTextView else {
            throw XCTSkip("Text field has no NSTextView field editor after the chip transition.")
        }
        editor2.insertText("fro", replacementRange: editor2.selectedRange())
        pump()
        let filtered = try writePNG(hosting, name: "07-live-chip-filtered")
        print("Rendered: \(filtered)")

        // Step 4: clear "fro" (3 plain backspaces, query non-empty each time — ordinary text
        // editing, not the chip-popping shortcut), then one more Backspace on the now-empty query,
        // which is what `.onKeyPress(.delete)` treats as "pop the chip" (keyCode 51, "\u{08}" — see
        // `sendKey`'s doc comment on why it's 0x08 and not 0x7F). Pumping after *every* keystroke
        // (not just at the end) matters: `query.isEmpty` is read from the SwiftUI `@State` binding,
        // which syncs from the field editor asynchronously — batching keystrokes without pumping
        // between them left `query` stale when the last delete's guard ran.
        sendKey(51, character: "\u{08}", to: window)
        pump()
        sendKey(51, character: "\u{08}", to: window)
        pump()
        sendKey(51, character: "\u{08}", to: window)
        pump()
        sendKey(51, character: "\u{08}", to: window)
        pump()
        let popped = try writePNG(hosting, name: "08-live-chip-popped")
        print("Rendered: \(popped)")
    }

    /// T3: the palette's third step — branch picker for "Merge branch" — is the one non-menu UI
    /// this task adds (see the plan's "Visual verification" note), so it gets the same live,
    /// real-key-events render as `testRender_liveChipStepTransition` above rather than a static
    /// snapshot: type "merge" → Return (picks the action, chip appears) → Return again (picks the
    /// first/alphabetically-earliest repo, moving to the branch step).
    @MainActor
    func testRender_liveBranchStep() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        let toasts = ToastCenter()
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}
        ).environment(toasts).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())

        let size = CGSize(width: 480, height: 420)
        let (hosting, window) = hostOffscreen(view, size: size)
        window.makeKey()
        defer { window.orderOut(nil) }

        func pump() { pumpRunLoop(hosting) }
        pump()

        func findTextField(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField { return tf }
            for sub in view.subviews {
                if let found = findTextField(in: sub) { return found }
            }
            return nil
        }
        guard let field = findTextField(in: hosting) else {
            throw XCTSkip("Could not locate the palette's NSTextField in the hosted view tree — cannot drive live typing offscreen.")
        }
        window.makeFirstResponder(field)
        pump()
        guard let editor = field.currentEditor() as? NSTextView else {
            throw XCTSkip("Text field has no NSTextView field editor after becoming first responder — cannot drive key handling offscreen.")
        }

        // Step 1: type "merge" and press Return — picks `.action(.mergeBranch)`, entering the
        // repository-picker step (the chip reads "Merge branch").
        editor.insertText("merge", replacementRange: editor.selectedRange())
        pump()
        sendKey(36, character: "\r", to: window)
        pump()

        // Step 2: press Return again on the (now highlighted, first alphabetically) repository row
        // — moves to the branch-picker step instead of running anything.
        sendKey(36, character: "\r", to: window)
        pump()

        let branchStep = try writePNG(hosting, name: "90-palette-branch-step")
        print("Rendered: \(branchStep)")
    }

    /// New ⌘K action through the two-step machinery: "rebase onto" → repository → branch step.
    func testRender_integRebaseOntoBranchStep() async throws {
        let workspace = try await makeWorkspace(named: repoNames)
        for repo in workspace.repositories { await repo.refreshStatus() }
        let view = CommandPalette(
            workspace: workspace, isPresented: .constant(true), openWorkspace: {}
        ).environment(ToastCenter()).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())

        let size = CGSize(width: 480, height: 420)
        let (hosting, window) = hostOffscreen(view, size: size)
        window.makeKey()
        defer { window.orderOut(nil) }
        func pump() { pumpRunLoop(hosting) }
        pump()
        func findTextField(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField { return tf }
            for sub in view.subviews { if let found = findTextField(in: sub) { return found } }
            return nil
        }
        guard let field = findTextField(in: hosting) else { throw XCTSkip("No palette text field offscreen.") }
        window.makeFirstResponder(field)
        pump()
        guard let editor = field.currentEditor() as? NSTextView else { throw XCTSkip("No field editor offscreen.") }
        editor.insertText("rebase onto", replacementRange: editor.selectedRange())
        pump()
        _ = try writePNG(hosting, name: "integ-04a-palette-rebase-query")
        sendKey(36, character: "\r", to: window) // → repository step
        pump()
        sendKey(36, character: "\r", to: window) // Backend → branch step
        pump()
        print("Rendered: \(try writePNG(hosting, name: "integ-04b-palette-rebase-branch-step"))")
    }

}
