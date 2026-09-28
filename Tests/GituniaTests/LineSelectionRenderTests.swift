import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of the real `DiffBodyView` with a line selection (via its
/// `initialLineSelection` seam) and the floating `LineSelectionBar` — same harness as
/// `BlameRenderTests`.
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter LineSelectionRenderTests
@MainActor
final class LineSelectionRenderTests: RenderTestCase {
    /// Real diff from a temp repo: a modified function with a replaced line and two additions.
    private func loadDiff(staged: Bool) async throws -> FileDiff {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-lines-render-\(UUID().uuidString)")
        let git = GitRunner()
        try await TestRepo.make(at: url, files: ["greeter.swift": "func greet() {\n    print(\"hello\")\n    return\n}\n"],
                                message: "greeter", user: "T", email: "t@example.com")
        let path = url.appendingPathComponent("greeter.swift")
        try "func greet() {\n    print(\"hello there\")\n    log(\"greeted\")\n    count += 1\n    return\n}\n".write(to: path, atomically: true, encoding: .utf8)
        if staged { _ = try await git.run(["add", "."], in: url) }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let change = try XCTUnwrap(store.repo.changes.first { $0.path == "greeter.swift" })
        let loaded = await store.diff(for: change)
        return try XCTUnwrap(loaded)
    }

    /// Selects the added `log(...)` line and the `count += 1` line.
    private func selection(in diff: FileDiff) -> Set<DiffLineRef> {
        Set(diff.hunks[0].lines.enumerated().compactMap { i, l in
            l.kind == .added && (l.text.contains("log") || l.text.contains("count")) ? DiffLineRef(hunk: 0, line: i) : nil
        })
    }

    private func body(_ diff: FileDiff, mode: DiffMode, staged: Bool) -> some View {
        DiffBodyView(diff: diff, mode: mode, fileExtension: "swift",
                     hunkActionLabel: staged ? "Unstage hunk" : "Stage hunk", hunkAction: { _ in },
                     lineActions: DiffLineActions(path: "greeter.swift", ops: staged ? [.unstage] : [.stage, .discard]) { _, _ in },
                     initialLineSelection: selection(in: diff))
    }

    private func render(_ view: some View, name: String, size: CGSize, colorScheme: ColorScheme) async throws {
        let root = view.frame(width: size.width, height: size.height).background(Color(nsColor: .textBackgroundColor)).preferredColorScheme(colorScheme)
        let path = try await renderHostedPNG(root, name: name, size: size, appearance: colorScheme == .dark ? .darkAqua : .aqua,
                                             activate: false, ticks: 15)
        print("Rendered: \(path)")
    }

    func testRender_inlineUnstaged() async throws {
        let diff = try await loadDiff(staged: false)
        try await render(body(diff, mode: .inline, staged: false), name: "lines-01-inline-unstaged", size: CGSize(width: 760, height: 300), colorScheme: .light)
    }

    func testRender_splitUnstaged() async throws {
        let diff = try await loadDiff(staged: false)
        try await render(body(diff, mode: .split, staged: false), name: "lines-02-split-unstaged", size: CGSize(width: 900, height: 300), colorScheme: .light)
    }

    func testRender_inlineStagedDark() async throws {
        let diff = try await loadDiff(staged: true)
        try await render(body(diff, mode: .inline, staged: true), name: "lines-03-inline-staged-dark", size: CGSize(width: 760, height: 300), colorScheme: .dark)
    }
}
