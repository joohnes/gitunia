import XCTest
import SwiftUI
import Combine
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// T0: verification of the four ⌘K focus problems, against the real production views
/// (`ChangesView`, `CommandPalette`, the `isPaletteOpen` environment key) rather than a
/// palette-only harness — so items 2 and 3 exercise the actual `List`/`onKeyPress` code underneath
/// the palette. Same offscreen-real-window technique as `CommandPaletteRenderTests`/
/// `ChangesViewRenderTests`; see those files' doc comments for why a real (if
/// offscreen-positioned) `NSWindow` is required for `List`/`NSTableView` content and any
/// first-responder behavior at all.
///
/// A note on what this harness can and can't see, learned while writing these tests (confirmed
/// with a throwaway standalone AppKit command-line harness, not part of this test target): in
/// this sandboxed XCTest host, `window.isKeyWindow` and `NSApp.isActive` are false no matter what
/// (`CommandPaletteRenderTests.sendKey`'s doc comment already established this for a different
/// reason). An *imperative* `window.makeFirstResponder(field)` still works fine regardless — the
/// original palette test suite relies on exactly that. But a SwiftUI `@FocusState` binding
/// flipping to `true` (`CommandPalette`'s deferred `searchFocused = true`, or `ChangesView`'s
/// `listFocused = true` restore) does **not** reliably translate into a real `NSResponder` change
/// on a non-key window here — SwiftUI appears to defer/skip applying reactive focus changes to a
/// window it doesn't consider active, which is reasonable production behavior (don't steal focus
/// in a background window) but makes "assert the field is first responder immediately after
/// opening, with no manual nudge" unverifiable in this harness. Item 1 and the second half of item
/// 3 are therefore verified as far as this environment allows — the palette/list are real,
/// enabled, working focus targets on every open/close, exercised with the same one-line
/// `makeFirstResponder` nudge the pre-existing `CommandPaletteRenderTests` already uses — and the
/// gap is called out explicitly rather than papered over.
@MainActor
final class CommandPaletteFocusTests: RenderTestCase {
    // MARK: - Fixture

    private func makeWorkspaceWithOneUnstagedChange() async throws -> (WorkspaceStore, RepositoryStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-focus-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("Backend")
        try await TestRepo.make(at: repoURL, files: ["README.md": "hello\n"])
        let readme = repoURL.appendingPathComponent("README.md")
        try "hello\nmodified\n".write(to: readme, atomically: true, encoding: .utf8)

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-focus-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else {
            throw XCTSkip("Repository did not scan into the workspace.")
        }
        await repo.refreshStatus()
        return (workspace, repo)
    }

    // MARK: - Harness

    /// A minimal stand-in for `ContentView`'s own `ChangesView` + `CommandPalette` overlay wiring
    /// — same structure (real `ChangesView`, real `CommandPalette`, the same `.environment(\.
    /// isPaletteOpen, ...)` key `ContentView` publishes), but with an externally-toggleable open
    /// state, since `ContentView.isPaletteOpen` is private `@State` with no injection seam and
    /// items 1–3 don't need the rest of `ContentView` (sidebar, toolbar, menu commands) to be
    /// meaningful. Item 4 tests the real `ContentView` directly instead, since it's specifically
    /// about `ContentView`'s own ⌘K monitor.
    private struct PaletteFocusHarness: View {
        var workspace: WorkspaceStore
        var repo: RepositoryStore
        var toggleName: Notification.Name
        @State private var isPaletteOpen = false
        @State private var selectedChange: FileChange?

        var body: some View {
            ChangesView(workspace: workspace, repo: repo, selectedChange: $selectedChange)
                .environment(\.isPaletteOpen, isPaletteOpen)
                .environment(ToastCenter())
                .environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
                .overlay {
                    if isPaletteOpen {
                        CommandPalette(
                            workspace: workspace,
                            isPresented: Binding(get: { isPaletteOpen }, set: { isPaletteOpen = $0 }),
                            openWorkspace: {}
                        )
                        .environment(ToastCenter())
                        .environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
                    }
                }
                .onAppear { selectedChange = repo.repo.changes.first }
                .onReceive(NotificationCenter.default.publisher(for: toggleName)) { _ in isPaletteOpen.toggle() }
        }
    }

    private func host(_ view: some View, size: CGSize = CGSize(width: 900, height: 620)) -> (NSHostingView<AnyView>, NSWindow) {
        let (hosting, window) = hostOffscreen(view, size: size)
        window.makeKey()
        return (hosting, window)
    }

    private func findTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let tf = view as? NSTextField { result.append(tf) }
        for sub in view.subviews { result += findTextFields(in: sub) }
        return result
    }

    /// The palette's search field's placeholder starts with "Search repositories" (`CommandPalette`:
    /// "Search repositories or run a command…" / "Search repositories…"). A plain substring check
    /// for "repositories" is not enough to identify it inside a real `ContentView` — the sidebar's
    /// own repository filter (`SidebarView`) has a `TextField("Filter repositories", ...)` that
    /// matches too, which is exactly the false-positive this test hit while it was being written
    /// (a "closed" palette kept "found" because the sidebar field matched instead).
    private func findPaletteField(in view: NSView) -> NSTextField? {
        findTextFields(in: view).first { ($0.placeholderString ?? "").hasPrefix("Search repositories") }
    }

    private func findChangesFilterField(in view: NSView) -> NSTextField? {
        findTextFields(in: view).first { $0.placeholderString == "Filter" }
    }

    // MARK: - Item 1: focus on open (including repeated opens)

    /// Every open produces a real, enabled, focusable search field — checked across three opens in
    /// a row, since item 1 explicitly calls out "also works on the second, third… open" (a fresh
    /// `CommandPalette` instance each time, per its own doc comment, is exactly the case that could
    /// regress across repeated opens). Automatic (no-manual-nudge) first-responder-on-appear is the
    /// one part of item 1 this harness cannot observe — see the type's doc comment for why
    /// (SwiftUI's own `@FocusState`-driven responder changes don't reach AppKit on a window this
    /// sandbox never lets become key, even though the same deferred-assignment code runs correctly
    /// up to that point). What *is* verified here: the field exists, is enabled, and genuinely
    /// accepts first responder (not just "found in the tree") on each of three consecutive opens.
    func testPaletteFieldIsFreshAndFocusableOnRepeatedOpens() async throws {
        let (workspace, repo) = try await makeWorkspaceWithOneUnstagedChange()
        let toggleName = Notification.Name("paletteToggle-\(UUID())")
        let view = PaletteFocusHarness(workspace: workspace, repo: repo, toggleName: toggleName)
        let (hosting, window) = host(view)
        defer { window.contentView = nil; pumpRunLoop(hosting, ticks: 10); window.orderOut(nil) }
        pumpRunLoop(hosting, ticks: 10)

        for openNumber in 1...3 {
            NotificationCenter.default.post(name: toggleName, object: nil) // open
            pumpRunLoop(hosting, ticks: 10)
            guard let field = findPaletteField(in: hosting) else {
                XCTFail("Open #\(openNumber) did not produce a palette field.")
                return
            }
            XCTAssertTrue(field.isEnabled, "Open #\(openNumber): palette field should be enabled.")
            XCTAssertTrue(window.makeFirstResponder(field), "Open #\(openNumber): palette field should accept first responder.")

            NotificationCenter.default.post(name: toggleName, object: nil) // close
            pumpRunLoop(hosting, ticks: 10)
            XCTAssertNil(findPaletteField(in: hosting), "Open #\(openNumber): palette should be gone after closing.")
        }
    }

    // MARK: - Item 2: keys must not leak to the changes list while the palette is open

    /// The worst case named in the task: typing "s" into an open palette must never stage a file
    /// in the repo underneath. The field is given focus with one manual `makeFirstResponder` call
    /// (see the type doc comment on why that nudge is needed in this harness, and why it doesn't
    /// weaken the test — this is the exact key-delivery path the pre-existing
    /// `CommandPaletteRenderTests` already relies on) so the "s" below travels the same route a
    /// real keystroke would once focus has landed correctly.
    func testTypingSWhilePaletteOpenDoesNotStageAFile() async throws {
        let (workspace, repo) = try await makeWorkspaceWithOneUnstagedChange()
        XCTAssertEqual(repo.unstagedChanges.count, 1, "Fixture should start with exactly one unstaged change.")
        XCTAssertEqual(repo.stagedChanges.count, 0)

        let toggleName = Notification.Name("paletteToggle-\(UUID())")
        let view = PaletteFocusHarness(workspace: workspace, repo: repo, toggleName: toggleName)
        let (hosting, window) = host(view)
        defer { window.contentView = nil; pumpRunLoop(hosting, ticks: 10); window.orderOut(nil) }
        pumpRunLoop(hosting, ticks: 10)

        NotificationCenter.default.post(name: toggleName, object: nil)
        pumpRunLoop(hosting, ticks: 10)
        guard let field = findPaletteField(in: hosting) else {
            XCTFail("Palette did not open.")
            return
        }
        window.makeFirstResponder(field)
        pumpRunLoop(hosting, ticks: 10)

        sendKey(1, character: "s", to: window)
        pumpRunLoop(hosting, ticks: 10)

        XCTAssertEqual(repo.unstagedChanges.count, 1, "The file must still be unstaged — 's' must not reach ChangesView's stage handler.")
        XCTAssertEqual(repo.stagedChanges.count, 0, "Typing 's' into the open palette staged a file — this is the bug item 2 exists to catch.")
    }

    /// Same guarantee in the other direction: "u" must not unstage a staged file while the palette
    /// is open and focused.
    func testTypingUWhilePaletteOpenDoesNotUnstageAFile() async throws {
        let (workspace, repo) = try await makeWorkspaceWithOneUnstagedChange()
        await repo.stage(repo.unstagedChanges[0])
        XCTAssertEqual(repo.stagedChanges.count, 1)
        XCTAssertEqual(repo.unstagedChanges.count, 0)

        let toggleName = Notification.Name("paletteToggle-\(UUID())")
        let view = PaletteFocusHarness(workspace: workspace, repo: repo, toggleName: toggleName)
        let (hosting, window) = host(view)
        defer { window.contentView = nil; pumpRunLoop(hosting, ticks: 10); window.orderOut(nil) }
        pumpRunLoop(hosting, ticks: 10)

        NotificationCenter.default.post(name: toggleName, object: nil)
        pumpRunLoop(hosting, ticks: 10)
        guard let field = findPaletteField(in: hosting) else {
            XCTFail("Palette did not open.")
            return
        }
        window.makeFirstResponder(field)
        pumpRunLoop(hosting, ticks: 10)

        sendKey(32, character: "u", to: window)
        pumpRunLoop(hosting, ticks: 10)

        XCTAssertEqual(repo.stagedChanges.count, 1, "The file must still be staged — 'u' must not reach ChangesView's unstage handler.")
        XCTAssertEqual(repo.unstagedChanges.count, 0, "Typing 'u' into the open palette unstaged a file — this is the bug item 2 exists to catch.")
    }

    /// `.focusable(!isPaletteOpen)` on the List is a SwiftUI-level focus-scope hint, not a raw
    /// `NSResponder.acceptsFirstResponder` gate: probed directly (`window.makeFirstResponder` on
    /// the List's internal `SwiftUIOutlineListView`, found by walking the real view tree), AppKit
    /// still accepts it as first responder while the palette is open, in this harness. That probe
    /// doesn't reflect what happens in the running app, though — a bypassed, from-outside
    /// `makeFirstResponder` call on that same internal view, made *without* going through SwiftUI's
    /// own focus system, was also confirmed (same throwaway probe) to leave "s" **not** reaching
    /// `ChangesView`'s `onKeyPress` handler even once forced first responder — i.e. raw AppKit
    /// first-responder status on this particular internal view isn't what actually gates whether a
    /// character key reaches a SwiftUI `.onKeyPress` handler; SwiftUI's own focus/key-routing layer
    /// does, and this harness has no supported way to drive that layer without a key window (see
    /// the type doc comment). The real, working defense for item 2 — proven above by two passing,
    /// full end-to-end tests that route "s"/"u" through the actual production key-delivery path
    /// (the palette's own focused `TextField`, exactly like a real keystroke) — is the explicit
    /// `guard !isPaletteOpen else { return .ignored }` in `ChangesView`'s and `DiffBodyView`'s own
    /// `onKeyPress` handlers. `.focusable(!isPaletteOpen)` remains in the source as a second,
    /// cheap layer for the one path this test can't drive (SwiftUI's own focus/Tab traversal
    /// choosing to land on the List while the palette is up), acknowledged here as unverified by
    /// this suite rather than asserted on the strength of a probe that turned out not to be
    /// representative.

    // MARK: - Item 3: focus returns to the file list after close

    /// `ChangesView.listFocused = true` on `isPaletteOpen` going false is exercised — every close in
    /// every test above and below runs through it without crashing, and the palette reliably leaves
    /// the view tree afterward (asserted repeatedly, e.g. in
    /// `testPaletteFieldIsFreshAndFocusableOnRepeatedOpens`). What this suite cannot additionally
    /// prove is that the *resulting* AppKit first-responder change actually lands: like item 1's
    /// automatic on-open focus, this is a `@FocusState` binding flipping outside of SwiftUI's own
    /// declarative focus system (Tab order, a real click), and — per the type doc comment — this
    /// sandboxed, never-key host does not reliably surface that as an observable `NSResponder`
    /// change, imperative `makeFirstResponder` calls made *from the test* notwithstanding (confirmed
    /// with a throwaway probe: forcing the List's internal view to first responder from outside
    /// SwiftUI's focus system, even when it succeeds, does not make a subsequent "s" reach
    /// `ChangesView`'s `onKeyPress`, so that path can't stand in for the real one either). This is
    /// the same category of gap item 1 and item 4's menu-key-equivalent routing already fall into —
    /// named explicitly rather than asserted on a probe that isn't the real mechanism.

    // MARK: - Item 4: ⌘K opens the real ContentView's palette, including from a text field, and
    // toggles closed when pressed again

    /// Drives the actual production entry point — `ContentView`'s own local `NSEvent` monitor
    /// (`installCmdKMonitorIfNeeded`), not a test seam — because item 4 is specifically about
    /// whether *that* mechanism (chosen over the menu's `.keyboardShortcut("k")`, which a focused
    /// `NSTextView` could in principle swallow before it ever reaches the menu — see that
    /// function's doc comment) actually fires regardless of what has focus, and does something
    /// sensible on a repeat press. All three sub-checks share one `ContentView` instance/one
    /// installed monitor deliberately: a local `NSEvent` monitor is registered process-wide on
    /// `NSApp`, not scoped to one window, and this sandboxed host never tears a SwiftUI view down
    /// (confirmed empirically — `.onDisappear` did not fire even after detaching and closing the
    /// window) — so a second `ContentView` in a second test would leave two monitors alive
    /// simultaneously, each toggling its own `@State`, and cross-contaminate every assertion in
    /// this method. One test, one monitor, no ambiguity.
    ///
    /// Confirmed empirically (a throwaway standalone AppKit command-line harness, not part of this
    /// target) that `NSApp.sendEvent` reaches a registered local monitor in this same sandboxed,
    /// never-active, never-key-window environment even though `window.sendEvent` — used everywhere
    /// else in this suite — does not, because local monitors hook `NSApplication.sendEvent`
    /// specifically.
    func testCmdKOpensFromTextFieldAndTogglesClosedOnRepeat() async throws {
        let (workspace, _) = try await makeWorkspaceWithOneUnstagedChange()
        let view = ContentView(workspace: workspace)
            .environment(ToastCenter()).environment(EditorOpenCoordinator()).environment(RemoteOpsCoordinator())
        let (hosting, window) = host(view)
        defer { window.contentView = nil; window.orderOut(nil) }
        pumpRunLoop(hosting, ticks: 10)

        func sendCmdK() {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
            )!
            NSApp.sendEvent(event)
        }

        // Sub-check A: ⌘K opens from a plain (no-focus) state.
        sendCmdK()
        pumpRunLoop(hosting, ticks: 10)
        XCTAssertNotNil(findPaletteField(in: hosting), "⌘K should open the palette.")

        // Sub-check B: ⌘K again while already open closes it — the chosen "sensible behavior" for
        // item 4's second question.
        sendCmdK()
        pumpRunLoop(hosting, ticks: 10)
        XCTAssertNil(findPaletteField(in: hosting), "A second ⌘K while the palette is open should close it.")

        // Sub-check C: ⌘K opens the palette even while the changes filter field (a real
        // NSTextField/NSTextView) has focus — the actual scenario item 4 is worried about.
        guard let filterField = findChangesFilterField(in: hosting) else {
            throw XCTSkip("Could not locate the changes filter field.")
        }
        XCTAssertTrue(window.makeFirstResponder(filterField), "Setup: filter field should accept focus.")
        pumpRunLoop(hosting, ticks: 10)

        sendCmdK()
        pumpRunLoop(hosting, ticks: 10)
        XCTAssertNotNil(findPaletteField(in: hosting), "⌘K should open the palette even while the changes filter field has focus.")
    }
}
