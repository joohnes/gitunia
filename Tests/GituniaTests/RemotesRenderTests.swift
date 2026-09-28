import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

final class RemovalMessageTests: XCTestCase {
    @MainActor
    func testRemovalMessageNamesRefsAndBranches() {
        let msg = RemotesSheet.removalMessage(name: "origin", impact: RemoteRemovalImpact(trackingRefCount: 3, trackingBranches: ["master", "feat"]))
        XCTAssertTrue(msg.contains("nothing on the server is deleted"))
        XCTAssertTrue(msg.contains("3 remote-tracking branches (origin/…)"))
        XCTAssertTrue(msg.contains("lose their upstream: master, feat."))
        let empty = RemotesSheet.removalMessage(name: "x", impact: RemoteRemovalImpact(trackingRefCount: 0, trackingBranches: []))
        XCTAssertFalse(empty.contains("upstream"))
    }
}

/// Offscreen render of the real `RemotesSheet` over a real temp repo with three remotes — two of
/// them with credentials in their URLs, which must come out redacted. Same harness as
/// `BlameRenderTests` (real offscreen `NSWindow`).
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter RemotesRenderTests
@MainActor
final class RemotesRenderTests: RenderTestCase {
    private func makeFixture() async throws -> (RepositoryStore, WorkspaceStore) {
        let base = try TestRepo.fixedRoot("remotes")
        let url = base.appendingPathComponent("app")
        let git = GitRunner()
        try await TestRepo.make(at: url, user: "T", email: "t@example.com")
        for args in [["init", "-q", "-b", "master", "--bare", base.appendingPathComponent("origin.git").path],
                     ["init", "-q", "-b", "master", "--bare", base.appendingPathComponent("backup.git").path],
                     ["remote", "add", "origin", base.appendingPathComponent("origin.git").path],
                     ["remote", "add", "backup", base.appendingPathComponent("backup.git").path],
                     ["push", "-q", "-u", "origin", "master"],
                     ["branch", "--track", "feat", "origin/master"],
                     ["remote", "set-url", "origin", "https://jan:ghp_S3CRETtoken@github.com/acme/app.git"],
                     ["remote", "add", "fork", "https://ghp_ANOTHERtoken@github.com/jan/app.git"],
                     ["remote", "set-url", "--push", "fork", "git@github.com:jan/app.git"]] {
            _ = try await git.run(args, in: url)
        }
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: base.appendingPathComponent("workspace.json")))
        let store = RepositoryStore(url: url)
        workspace.setDefaultRemote("backup", for: store)
        await store.refreshStatus()
        return (store, workspace)
    }

    private func sheet(_ store: RepositoryStore, _ workspace: WorkspaceStore, _ editor: RemotesSheet.EditorState? = nil) -> some View {
        RemotesSheet(store: store, workspace: workspace, toasts: ToastCenter(), initialEditor: editor)
    }

    func testRender_01_list() async throws {
        let (store, ws) = try await makeFixture()
        print("Rendered:", try await renderPNG(sheet(store, ws), name: "remotes-01-list", size: CGSize(width: 520, height: 400)))
    }

    func testRender_02_listDark() async throws {
        let (store, ws) = try await makeFixture()
        print("Rendered:", try await renderPNG(sheet(store, ws), name: "remotes-02-list-dark", size: CGSize(width: 520, height: 400), colorScheme: .dark))
    }

    func testRender_03_addDuplicate() async throws {
        let (store, ws) = try await makeFixture()
        let problem = await store.validateRemoteName("origin")
        XCTAssertNotNil(problem)
        let editor = RemotesSheet.EditorState(kind: .add, name: "origin", url: "https://github.com/acme/app.git", problem: problem)
        print("Rendered:", try await renderPNG(sheet(store, ws, editor), name: "remotes-03-add-duplicate", size: CGSize(width: 520, height: 560)))
    }

    func testRender_04_removeConfirm() async throws {
        let (store, ws) = try await makeFixture()
        let impact = await store.removalImpact(of: "origin")
        XCTAssertEqual(impact.trackingBranches, ["feat", "master"])
        let editor = RemotesSheet.EditorState(kind: .remove("origin", impact))
        print("Rendered:", try await renderPNG(sheet(store, ws, editor), name: "remotes-04-remove-confirm", size: CGSize(width: 520, height: 560)))
    }

    func testRender_05_changeURL() async throws {
        let (store, ws) = try await makeFixture()
        let remotes = await store.listRemotes()
        let origin = try XCTUnwrap(remotes.first { $0.name == "origin" })
        let editor = RemotesSheet.EditorState(kind: .changeURL(origin))
        print("Rendered:", try await renderPNG(sheet(store, ws, editor), name: "remotes-05-change-url", size: CGSize(width: 520, height: 560)))
    }
}
