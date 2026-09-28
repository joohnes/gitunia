import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for spec item 5 ("Simple editing"): the editor itself, and the
/// "changed on disk" dialog it shows before overwriting a concurrently-modified file.
///
/// Renders `EditFileView` directly rather than `DiffView` — `DiffView`'s Edit/Done toggle
/// (`isEditing`) is private `@State`, and (per `ActionRowRenderTests`'s and
/// `ChangesViewRenderTests`'s notes) toolbar items don't composite in an offscreen
/// `cacheDisplay:` snapshot anyway, so there is no way to drive `DiffView` into edit mode from
/// outside and have the toolbar Edit button itself show up regardless. `EditFileView` is the real
/// production editor view (not a stand-in copy) that `DiffView` swaps in — this exercises it
/// directly, including its real `EditSession`/`FileEditor` save path for the conflict dialog.
///
/// Disabled by default, same env var as the other render harnesses:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter EditFileViewRenderTests
@MainActor
final class EditFileViewRenderTests: RenderTestCase {
    private func render(_ view: some View, name: String, size: CGSize) async throws -> (String, NSHostingView<AnyView>, NSWindow) {
        let (hosting, window) = hostOffscreen(view, size: size)
        await pumpLayout(hosting, ticks: 15)
        return (try writePNG(hosting, name: name), hosting, window)
    }

    private func makeSmallFile(content: String = "func greet() {\n    print(\"hello\")\n}\n") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-edit-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Greeting.swift")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testRender_editMode() async throws {
        let file = try makeSmallFile()
        let toasts = ToastCenter()
        let session = EditSession()
        let view = EditFileView(fileURL: file, editSession: session, onSaved: {}, onLoadFailed: {})
            .environment(toasts)
        let (path, _, window) = try await render(view, name: "50-edit-mode", size: CGSize(width: 500, height: 320))
        defer { window.orderOut(nil) }
        print("Rendered: \(path)")
    }

    /// Drives the real concurrent-modification path: loads the file into the editor (capturing its
    /// mtime/content snapshot), then changes the file on disk — simulating an agent writing to it
    /// — and invokes the real `EditSession.saveAction` (exactly what ⌘S/Done route through). That
    /// runs `EditFileView.save()`, which calls the real, tested `FileEditor.concurrentChange`, gets
    /// `.conflict`, and presents the real `.confirmationDialog`.
    func testRender_changedOnDiskDialog() async throws {
        let file = try makeSmallFile()
        let toasts = ToastCenter()
        let session = EditSession()
        let view = EditFileView(fileURL: file, editSession: session, onSaved: {}, onLoadFailed: {})
            .environment(toasts)
        let (_, hosting, window) = try await render(view, name: "51-edit-conflict-before", size: CGSize(width: 500, height: 320))
        defer { window.orderOut(nil) }

        guard session.saveAction != nil else {
            throw XCTSkip("EditFileView did not finish loading — nothing to save, can't reach the conflict dialog.")
        }

        // Simulate the concurrent write this dialog exists for: something else changes the file's
        // bytes after this editor loaded it, before the user saves.
        try "func greet() {\n    print(\"hello, agent\")\n}\n".write(to: file, atomically: true, encoding: .utf8)

        // Fire the save through the real seam (`EditSession.saveAction`) without awaiting
        // completion — `save()` will suspend on the confirmation dialog's continuation, which
        // nothing in this test resolves, so awaiting it directly would hang forever.
        Task { _ = await session.saveAction?() }
        await pumpLayout(hosting)

        let path = try writePNG(hosting, name: "51-edit-conflict")
        print("Rendered: \(path)")
        print("If this looks identical to 50-edit-mode.png (minus content), the confirmationDialog — an NSPanel-backed sheet — did not composite into the parent NSHostingView's cacheDisplay snapshot, the same way other alerts/sheets in this codebase's render harnesses don't; that would mean this dialog can't be verified this way, only inspected in a real run.")
    }
}
