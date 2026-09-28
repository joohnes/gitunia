import XCTest
@testable import Gitunia
@testable import GituniaCore

@MainActor
final class WorkspaceActionsTests: XCTestCase {
    /// Undo from a toast posted in workspace A must not touch workspace B once the window switched.
    func testUndoRemovalIgnoredAfterWorkspaceSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-undo-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await GitRunner().run(["init", "-q", "-b", "master"], in: repo)
        let store = WorkspaceStore(app: AppConfig(configStore: ConfigStore(fileURL: root.appendingPathComponent("workspace.json"))),
                                   saveDebounce: .milliseconds(10))
        await store.openUntitled()
        let urlA = store.fileURL
        let storeA = try await store.addRepository(repo)
        let removal = try XCTUnwrap(store.remove(storeA))

        await store.openUntitled()   // window now shows workspace B
        await WorkspaceActions.undoRemoval(removal, in: store, ifStillAt: urlA)
        XCTAssertTrue(store.file.isEmpty, "undo must not leak into B")

        let urlB = store.fileURL
        let storeB = try await store.addRepository(repo)
        let removalB = try XCTUnwrap(store.remove(storeB))
        await WorkspaceActions.undoRemoval(removalB, in: store, ifStillAt: urlB)
        XCTAssertEqual(store.repositories.map(\.repo.name), ["a"], "same workspace: undo applies")
        store.stopWatching()
    }
}
