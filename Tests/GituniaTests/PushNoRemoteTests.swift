import XCTest
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
}
