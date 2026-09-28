import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for G2/T2 (file history + restore) — same technique as
/// `HistorySearchRenderTests`/`CommitDiffTreeRenderTests` (offscreen `NSHostingView`, no Screen
/// Recording permission needed).
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter FileHistoryRenderTests
@MainActor
final class FileHistoryRenderTests: RenderTestCase {
    /// `110-file-history.png`: `HistoryView` in file-history mode (the "File: <path>" chip, no
    /// branch picker/free-text filter) side by side with `CommitDiffView` preselecting the file at
    /// its path in the selected commit — including an entry from before a rename (the file started
    /// as `notes/plan.txt`, was renamed to `notes/final_plan.txt`), matching production's
    /// content+detail layout.
    func testRender_fileHistoryWithRename() async throws {
        let root = try TestRepo.fixedRoot("file-history")
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

        try write("notes/plan.txt", "step one\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "add the plan"], date: TestRepo.fixedDate.addingTimeInterval(3600))

        try write("notes/plan.txt", "step one\nstep two\n")
        _ = try await git.run(["add", "."], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "extend the plan"], date: TestRepo.fixedDate.addingTimeInterval(7200))

        _ = try await git.run(["mv", "notes/plan.txt", "notes/final_plan.txt"], in: repoURL)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "rename plan to final_plan"], date: TestRepo.fixedDate.addingTimeInterval(10_800))

        try write("notes/final_plan.txt", "step one\nstep two\nstep three\n")
        _ = try await git.run(["add", "."], in: repoURL)
        // Agent by email only (author name stays "Test") — the row's `cpu` glyph proves `%ae` flows
        // through `fileHistory`.
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-m", "add step three"],
                                      date: TestRepo.fixedDate.addingTimeInterval(14_400), user: "Test", email: "agent@example.com")

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-file-history-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first else { throw XCTSkip("Repository did not scan into the workspace.") }
        let entries = await repo.fileHistory(path: "notes/final_plan.txt")
        XCTAssertEqual(entries.filter { repo.agentProfile.matches(author: $0.commit.author, email: $0.authorEmail) }.map(\.commit.subject), ["add step three"])

        let toasts = ToastCenter()
        let editorRequests = EditorOpenCoordinator()
        var selection: CommitInfo?
        var fileHistoryPath: String? = "notes/final_plan.txt"
        var fileHistorySelectedPath: String?
        var selectedPath: String?

        let historyView = HistoryView(
            repo: repo,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            fileHistoryPath: Binding(get: { fileHistoryPath }, set: { fileHistoryPath = $0 }),
            fileHistorySelectedPath: Binding(get: { fileHistorySelectedPath }, set: { fileHistorySelectedPath = $0 })
        ).environment(toasts).frame(width: 300)

        let size = CGSize(width: 900, height: 460)
        let (hosting, window) = hostOffscreen(historyView, size: size)
        defer { window.orderOut(nil) }
        await pumpLayout(hosting)

        // By now file history has loaded and auto-selected the newest entry; grab it and mount the
        // commit diff pane beside it, preselecting the file the same way `ContentView` would.
        guard let selected = selection else { throw XCTSkip("File history did not select a commit.") }
        let commitDiffView = CommitDiffView(
            workspace: workspace, repo: repo, commit: selected,
            selectedPath: Binding(get: { selectedPath }, set: { selectedPath = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            preselectPath: fileHistorySelectedPath
        ).environment(toasts).environment(editorRequests)

        let combined = HStack(spacing: 0) {
            historyView.frame(width: 300)
            Divider()
            commitDiffView.frame(maxWidth: .infinity)
        }
        let (hostingCombined, windowCombined) = hostOffscreen(combined, size: size)
        defer { windowCombined.orderOut(nil) }
        await pumpLayout(hostingCombined)
        let path = try writePNG(hostingCombined, name: "110-file-history")
        print("Rendered: \(path)")
    }
}
