import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for T1's three new UI pieces: the rebase-in-progress banner, the
/// conflict row's rebase-specific labels ("Keep Upstream"/"Keep My Commit" instead of "Use Mine"/
/// "Use Theirs" — the two are opposite in meaning during a rebase, see `RepositoryStore.useOurs`),
/// and a toast's "Force push…" action button.
///
/// Disabled by default, same as every other render harness in this suite:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter RebaseForcePushRenderTests
@MainActor
final class RebaseForcePushRenderTests: RenderTestCase {
    private func renderPlain(_ view: some View, name: String, size: CGSize = CGSize(width: 420, height: 90)) throws -> String {
        try renderPlainPNG(view, name: name, size: size)
    }

    private func renderWindowed(_ view: some View, name: String, size: CGSize = CGSize(width: 340, height: 460)) async throws -> String {
        try await renderHostedPNG(view, name: name, size: size, ticks: 15)
    }

    /// 70-rebase-banner.png: the banner in isolation. `RebaseBanner` was generalised into
    /// `OperationBanner` in T2 (merge/rebase/cherry-pick/revert); this render keeps the original
    /// rebase case.
    func testRender_rebaseBanner() throws {
        let view = OperationBanner(operation: .rebase, continueDisabled: false, onContinue: {}, onSkip: {}, onAbort: {})
        let path = try renderPlain(view, name: "70-rebase-banner")
        print("Rendered: \(path)")
    }

    /// A real repo stopped mid-rebase on a genuine content conflict (two clones editing the same
    /// line, same setup verified against real git in `RemoteOpsTests.makeConflictingRebase`) — not
    /// a synthetic `FileChange`, so the Conflicts section and its "Keep Upstream"/"Keep My Commit"
    /// labels reflect what the app would actually show.
    private func makeRebaseConflictRepo() async throws -> (WorkspaceStore, RepositoryStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-rebase-render-\(UUID().uuidString)")
        let aURL = root.appendingPathComponent("A")
        let git = GitRunner()
        try await TestRepo.make(at: aURL, files: ["f.txt": "line1\n"], message: "add f.txt")

        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-rebase-render-remote-\(UUID().uuidString).git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: aURL)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: aURL)
        _ = try await git.run(["push", "-q", "-u", "origin", "HEAD"], in: aURL)

        let bURL = root.appendingPathComponent("B")
        _ = try await git.run(["clone", "-q", remote.path, bURL.path], in: aURL)
        _ = try await git.run(["config", "user.email", "test@example.com"], in: bURL)
        _ = try await git.run(["config", "user.name", "Test"], in: bURL)
        _ = try await git.run(["config", "commit.gpgsign", "false"], in: bURL)

        try "line1-A\n".write(to: aURL.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "-A"], in: aURL)
        _ = try await git.run(["commit", "-q", "-m", "A changes line1"], in: aURL)
        _ = try await git.run(["push", "-q"], in: aURL)

        try "line1-B\n".write(to: bURL.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "-A"], in: bURL)
        _ = try await git.run(["commit", "-q", "-m", "B changes line1"], in: bURL)
        _ = try await git.run(["fetch", "-q"], in: bURL)

        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-rebase-render-config-\(UUID().uuidString).json")
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: configFile))
        await workspace.openUntitled(linkingFolder: root)
        guard let repoB = workspace.repositories.first(where: { $0.repo.name == "B" }) else {
            throw XCTSkip("Repository B did not scan into the workspace.")
        }
        _ = await repoB.pullRebase()
        await repoB.refreshStatus()
        return (workspace, repoB)
    }

    /// 71-rebase-conflict-row.png: the full `ChangesView` — rebase banner plus the Conflicts
    /// section with its rebase-specific "Keep Upstream"/"Keep My Commit" buttons — over a repo
    /// genuinely stopped on a rebase conflict.
    func testRender_rebaseConflictRow() async throws {
        let (workspace, repoB) = try await makeRebaseConflictRepo()
        XCTAssertTrue(repoB.rebaseInProgress, "setup didn't actually stop on a rebase conflict")
        XCTAssertEqual(repoB.conflictedChanges.map(\.path), ["f.txt"])
        var selectedChange: FileChange?
        let binding = Binding<FileChange?>(get: { selectedChange }, set: { selectedChange = $0 })
        let view = ChangesView(workspace: workspace, repo: repoB, selectedChange: binding)
            .environment(ToastCenter()).environment(EditorOpenCoordinator())
        let path = try await renderWindowed(view, name: "71-rebase-conflict-row")
        print("Rendered: \(path)")
    }

    /// 72-toast-force-action.png: an error toast (rejected push) carrying the "Force push…" action
    /// button, rendered through the real `ToastOverlay`/`ToastCenter`, not a mocked-up row.
    func testRender_toastWithForcePushAction() throws {
        let toasts = ToastCenter()
        toasts.post(.error("Backend", detail: RemoteOpsCoordinator.rejectedPushDetail(branch: "master"), stderr: "! [rejected]  master -> master (fetch first)",
                            action: ToastAction(title: "Force push…") {}))
        let view = ToastOverlay().environment(toasts)
        let path = try renderPlain(view, name: "72-toast-force-action", size: CGSize(width: 400, height: 140))
        print("Rendered: \(path)")
    }
}
