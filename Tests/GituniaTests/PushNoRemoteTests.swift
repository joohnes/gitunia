import XCTest
import SwiftUI
@testable import Gitunia
import GituniaCore

/// A push with no remote at all asks for a URL (`pendingAddRemote`) instead of just toasting an
/// error; entering one adds "origin" and pushes, setting the upstream.
@MainActor
final class PushNoRemoteTests: XCTestCase {
    private func makeRepo() async throws -> (repo: URL, bare: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-noremote-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("w"), bare = base.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master"], in: repo)
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", bare.path], in: repo)
        _ = try await git.run(["-c", "user.email=t@e", "-c", "user.name=T", "-c", "commit.gpgsign=false",
                               "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        return (repo, bare)
    }

    func testPushWithoutRemoteAsksForURLThenAddsOriginAndPushes() async throws {
        let (url, bare) = try await makeRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let coordinator = RemoteOpsCoordinator()
        let toasts = ToastCenter()

        await coordinator.requestPush(on: store, toasts: toasts)
        XCTAssertTrue(coordinator.pendingAddRemote === store)
        XCTAssertFalse(toasts.toasts.contains { $0.style == .error })

        await coordinator.addOriginAndPush(on: store, url: bare.path, toasts: toasts)
        XCTAssertNil(coordinator.pendingAddRemote)
        XCTAssertTrue(store.hasUpstream)
        XCTAssertTrue(toasts.toasts.contains { $0.style == .success }, "\(toasts.toasts.map(\.detail))")
    }

    /// `toast-details.png`: the popover body for a real failed push, rendered directly (popovers
    /// never composite offscreen).
    func testRender_toastDetails() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_PALETTE_RENDER_TESTS"] == "1")
        let toast = Toast.error("gitunia", detail: "Push failed",
            stderr: "To github.com:you/gitunia.git\n ! [rejected]        master -> master (fetch first)\nerror: failed to push some refs to 'github.com:you/gitunia.git'\nhint: Updates were rejected because the remote contains work that you do not\nhint: have locally.",
            command: "git push")
        let hosting = NSHostingView(rootView: ToastDetails(toast: toast).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 460, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 50_000_000); hosting.layoutSubtreeIfNeeded() }
        let path = try writePNG(hosting, name: "toast-details")
        print("Rendered: \(path)")
    }
}
