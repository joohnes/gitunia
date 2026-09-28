import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for G2/T3 (blame) — same technique as `ActionRowRenderTests`
/// (real, if offscreen-positioned, `NSWindow`; `AppKit` toolbar/toggle controls don't composite
/// for `cacheDisplay:` without one), rendering `DiffView` itself with its `initialBlame` test seam
/// rather than a copy of the blame UI, so what's captured is exactly what production draws.
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter BlameRenderTests
@MainActor
final class BlameRenderTests: RenderTestCase {
    /// Three commits, two authors, plus one uncommitted line — matches the visual-verification
    /// spec exactly. Distinct content per line (not just "line N") so the syntax highlighting and
    /// gutter both have something real to show.
    private func makeRepoWithBlameHistory() async throws -> (RepositoryStore, FileChange) {
        let url = try TestRepo.fixedRoot("blame")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master"], in: url)
        _ = try await git.run(["config", "commit.gpgsign", "false"], in: url)

        func write(_ text: String) throws {
            try text.write(to: url.appendingPathComponent("greeter.swift"), atomically: true, encoding: .utf8)
        }

        try write("func greet() {\n    print(\"hello\")\n}\n")
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "add greeter"],
                                      date: TestRepo.fixedDate, user: "Alice", email: "alice@example.com")

        try write("func greet() {\n    print(\"hello there\")\n}\n")
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "friendlier greeting"],
                                      date: TestRepo.fixedDate.addingTimeInterval(3600), user: "Bob", email: "bob@example.com")

        try write("func greet() {\n    print(\"hello there\")\n    print(\"welcome\")\n}\n")
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "welcome message"],
                                      date: TestRepo.fixedDate.addingTimeInterval(7200), user: "Alice", email: "alice@example.com")

        // Uncommitted: an appended trailing line, never staged.
        try write("func greet() {\n    print(\"hello there\")\n    print(\"welcome\")\n}\n// TODO: localize\n")

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let change = try XCTUnwrap(store.repo.changes.first { $0.path == "greeter.swift" })
        return (store, change)
    }

    private func render(_ view: some View, name: String, size: CGSize, colorScheme: ColorScheme) async throws -> String {
        try await renderHostedPNG(view.preferredColorScheme(colorScheme), name: name, size: size,
                                  appearance: colorScheme == .dark ? .darkAqua : .aqua)
    }

    private func diffView(_ store: RepositoryStore, _ change: FileChange) -> some View {
        DiffView(repo: store, change: change, editSession: EditSession(), initialBlame: true)
    }

    /// `120-blame.png`: light appearance.
    func testRender_blameLight() async throws {
        let (store, change) = try await makeRepoWithBlameHistory()
        let path = try await render(diffView(store, change), name: "120-blame", size: CGSize(width: 760, height: 420), colorScheme: .light)
        print("Rendered: \(path)")
    }

    /// `121-blame-dark.png`: dark appearance, same content.
    func testRender_blameDark() async throws {
        let (store, change) = try await makeRepoWithBlameHistory()
        let path = try await render(diffView(store, change), name: "121-blame-dark", size: CGSize(width: 760, height: 420), colorScheme: .dark)
        print("Rendered: \(path)")
    }
}
