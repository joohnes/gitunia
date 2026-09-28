import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for T2's three new UI pieces: `HistoryView`'s branch picker
/// showing a non-current branch, the operation banner for a cherry-pick stopped on conflicts, and
/// `CommitBox` hidden/disabled while an operation is in progress.
///
/// Disabled by default, same env var as every other render harness in this suite:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter T2OperationRenderTests
@MainActor
final class T2OperationRenderTests: RenderTestCase {
    private func renderPlain(_ view: some View, name: String, size: CGSize = CGSize(width: 420, height: 90)) throws -> String {
        try renderPlainPNG(view, name: name, size: size)
    }

    private func renderWindowed(_ view: some View, name: String, size: CGSize = CGSize(width: 340, height: 460)) async throws -> String {
        try await renderHostedPNG(view, name: name, size: size, ticks: 15)
    }

    /// A repo with a `feature` branch carrying two extra commits not on `master`, so the branch
    /// picker has something real to switch to and the history list shows genuinely different
    /// content per branch.
    private func makeRepoWithFeatureBranch() async throws -> RepositoryStore {
        let url = try TestRepo.fixedRoot("history-branch")
        let git = GitRunner()
        try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: url)
        for (i, name) in ["Add login screen", "Wire up API client"].enumerated() {
            try "\(name)\n".write(to: url.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: url)
            _ = try await TestRepo.commit(at: url, args: ["-q", "-m", name], date: TestRepo.fixedDate.addingTimeInterval(TimeInterval(i + 1) * 3600))
        }
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return store
    }

    /// 80-history-branch-picker.png: `HistoryView` with the picker showing "feature" (not the
    /// current branch, "master") and its two commits.
    func testRender_historyBranchPicker() async throws {
        let store = try await makeRepoWithFeatureBranch()
        var selection: CommitInfo?
        let binding = Binding<CommitInfo?>(get: { selection }, set: { selection = $0 })
        let view = HistoryView(repo: store, selection: binding, initialBranch: "feature")
            .environment(ToastCenter())
        let path = try await renderWindowed(view, name: "80-history-branch-picker")
        print("Rendered: \(path)")
    }

    /// A real repo genuinely stopped mid-cherry-pick on a content conflict (two branches editing
    /// the same line), the same setup verified against real git in `OperationTests`.
    private func makeCherryPickConflictRepo() async throws -> (WorkspaceStore, RepositoryStore) {
        let root = try TestRepo.fixedRoot("cherrypick")
        let repoURL = root.appendingPathComponent("Backend")
        let git = GitRunner()
        try await TestRepo.make(at: repoURL, files: ["f.txt": "line1\n"], message: "add f.txt")

        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: repoURL)
        try "line1-feature\n".write(to: repoURL.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-am", "feature changes line1"], date: TestRepo.fixedDate.addingTimeInterval(3600))
        let pickHash = try await git.run(["rev-parse", "HEAD"], in: repoURL).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await git.run(["checkout", "-q", "master"], in: repoURL)
        try "line1-master\n".write(to: repoURL.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await TestRepo.commit(at: repoURL, args: ["-q", "-am", "master changes line1"], date: TestRepo.fixedDate.addingTimeInterval(7200))

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-cherrypick-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repo = workspace.repositories.first(where: { $0.repo.name == "Backend" }) else {
            throw XCTSkip("Repository did not scan into the workspace.")
        }
        _ = await repo.cherryPick(pickHash)
        await repo.refreshStatus()
        return (workspace, repo)
    }

    /// 81-cherrypick-banner.png: the full `ChangesView` — the generalised operation banner reading
    /// "Cherry-pick in progress" (with Continue disabled while the conflict remains, and Skip
    /// present since cherry-pick offers it) plus the Conflicts section.
    func testRender_cherryPickBanner() async throws {
        let (workspace, repo) = try await makeCherryPickConflictRepo()
        XCTAssertEqual(repo.operation, .cherryPick, "setup didn't actually stop on a cherry-pick conflict")
        XCTAssertEqual(repo.conflictedChanges.map(\.path), ["f.txt"])
        var selectedChange: FileChange?
        let binding = Binding<FileChange?>(get: { selectedChange }, set: { selectedChange = $0 })
        let view = ChangesView(workspace: workspace, repo: repo, selectedChange: binding)
            .environment(ToastCenter()).environment(EditorOpenCoordinator())
        let path = try await renderWindowed(view, name: "81-cherrypick-banner")
        print("Rendered: \(path)")
    }

    /// 82-commitbox-during-op.png: `CommitBox` on its own, showing the "in progress" message
    /// instead of the title/body/Commit form — verifies T2's fix for T1's known defect (the commit
    /// box stayed usable during a rebase).
    func testRender_commitBoxDuringOperation() async throws {
        let (workspace, repo) = try await makeCherryPickConflictRepo()
        XCTAssertEqual(repo.operation, .cherryPick)
        let view = CommitBox(workspace: workspace, repo: repo)
            .environment(ToastCenter())
            .environment(RemoteOpsCoordinator())
            .padding(12)
        let path = try renderPlain(view, name: "82-commitbox-during-op", size: CGSize(width: 340, height: 80))
        print("Rendered: \(path)")
    }

    /// 83/84-commitbox-generate-<width>.png: nothing staged, so the Generate button reads "Stage all
    /// & Generate" when it fits and collapses to its icon (tooltip keeps the words) when it doesn't —
    /// never a truncated label.
    func testRender_commitBoxGenerateNarrowAndWide() async throws {
        let (workspace, repo) = try await makeCherryPickConflictRepo()
        _ = await repo.abortOperation()
        try "edited\n".write(to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        await repo.refreshStatus()
        XCTAssertNil(repo.operation)
        XCTAssertTrue(repo.stagedChanges.isEmpty)
        for width in [260, 380] {
            let view = CommitBox(workspace: workspace, repo: repo)
                .environment(ToastCenter())
                .environment(RemoteOpsCoordinator())
                .padding(12)
            let path = try await renderWindowed(view, name: "83-commitbox-generate-\(width)", size: CGSize(width: width, height: 200))
            print("Rendered: \(path)")
        }
    }
}
