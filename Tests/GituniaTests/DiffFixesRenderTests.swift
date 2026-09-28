import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for the 2026-09-23 swarm review's diff/edit/blame fixes:
///   - M9 (security): a working-tree symlink shows "Symlink → <target>", never the target's bytes.
///   - L1: Scope/Diff mode/Wrap are disabled (with a `.help` reason) for a binary file, matching
///     how Blame/Edit already explain themselves.
///
/// Same real-(offscreen-positioned)-`NSWindow` technique as `BlameRenderTests` for the symlink
/// case (AppKit controls, and here the toolbar guard's *content* branch, don't composite for
/// `cacheDisplay:` without a real window). The toolbar case reuses `ActionRowRenderTests`'
/// titled-window-plus-real-`NSToolbar` technique (`renderToolbar`) and captures the window's theme
/// frame, not just the content view — the toolbar itself lives in the theme frame, and per
/// `EditFileViewRenderTests`'s note, a `.toolbar` item never composites into a plain content-view
/// snapshot without one.
///
/// Disabled by default, same env var as the other render harnesses:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter DiffFixesRenderTests
@MainActor
final class DiffFixesRenderTests: RenderTestCase {
    private func render(_ view: some View, name: String, size: CGSize) async throws -> String {
        try await renderHostedPNG(view, name: name, size: size, appearance: .aqua)
    }

    private func renderToolbar(_ view: some View, name: String, size: CGSize) async throws -> String {
        try await renderToolbarPNG(view.frame(width: size.width, height: size.height), name: name, size: size,
                                   toolbar: "diff-fixes-toolbar-fixture", appearance: .aqua)
    }

    private func makeTempRepo() async throws -> URL {
        let url = try TestRepo.fixedRoot("difffixes")
        return try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
    }

    // MARK: - M9: symlink

    /// An untracked symlink pointing outside the repo, at a "secret" file — the same shape as the
    /// finding (`notes.txt -> ~/.ssh/id_rsa`). `DiffView` must show "Symlink → <target>" and never
    /// the secret file's contents.
    private func makeRepoWithSymlink() async throws -> (RepositoryStore, FileChange, URL) {
        let url = try await makeTempRepo()
        let secretDir = try TestRepo.fixedRoot("difffixes-secret")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secret = secretDir.appendingPathComponent("id_rsa")
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nTOTALLY-SECRET\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(to: secret, atomically: true, encoding: .utf8)

        let link = url.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let change = try XCTUnwrap(store.repo.changes.first { $0.path == "notes.txt" })
        return (store, change, secret)
    }

    /// `fix-diff-01-symlink.png`: opening the symlink shows "Symlink → <target path>" — proving the
    /// diff pane never read (and so never could display) the target file's bytes.
    func testRender_symlinkShowsTargetNotBytes() async throws {
        let (store, change, secret) = try await makeRepoWithSymlink()
        let view = DiffView(repo: store, change: change, editSession: EditSession())
        let path = try await render(view, name: "fix-diff-01-symlink", size: CGSize(width: 700, height: 200))
        print("Rendered: \(path) — target was \(secret.path)")
    }

    // MARK: - L1: toolbar disabled for a binary file

    private func makeRepoWithBinaryChange() async throws -> (RepositoryStore, FileChange) {
        let url = try await makeTempRepo()
        let file = url.appendingPathComponent("logo.bin")
        // NUL byte anywhere in the sampled prefix is what makes `git diff` call a file binary.
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03]).write(to: file)
        let git = GitRunner()
        _ = try await git.run(["add", "."], in: url)
        _ = try await git.run(["commit", "-q", "-m", "add binary"], in: url)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xEE, 0xDD]).write(to: file)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let change = try XCTUnwrap(store.repo.changes.first { $0.path == "logo.bin" })
        return (store, change)
    }

    /// `fix-diff-02-binary-toolbar.png`: Scope/Diff mode/Wrap all render greyed out once the diff
    /// finishes loading and reports `isBinary == true` — they no longer sit there fully enabled
    /// doing nothing.
    func testRender_binaryFileDisablesShapingToolbar() async throws {
        let (store, change) = try await makeRepoWithBinaryChange()
        let view = DiffView(repo: store, change: change, editSession: EditSession())
        let path = try await renderToolbar(view, name: "fix-diff-02-binary-toolbar", size: CGSize(width: 900, height: 260))
        print("Rendered: \(path)")
    }
}
