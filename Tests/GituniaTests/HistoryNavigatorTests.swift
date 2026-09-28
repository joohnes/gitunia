import XCTest
@testable import Gitunia
import GituniaCore

@MainActor
final class HistoryNavigatorTests: XCTestCase {
    private func makeRepo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-nav-\(UUID().uuidString)")
        return try await TestRepo.make(at: url, user: "T", email: "t@e.com")
    }

    private func makeRegistry() -> WorkspaceRegistry {
        let cfg = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-nav-\(UUID().uuidString)/workspace.json")
        return WorkspaceRegistry(app: AppConfig(configStore: ConfigStore(fileURL: cfg)))
    }

    func testShowSelectsTheRepoAndPublishesPending() async throws {
        let registry = makeRegistry()
        registry.newWindow()
        let id = try XCTUnwrap(registry.windowOrder.first)
        let store = await registry.attachWindow(id)
        let a = try await store.addRepository(try await makeRepo())
        let b = try await store.addRepository(try await makeRepo())
        store.selectedRepoID = a.id

        XCTAssertTrue(registry.navigator.show(commit: "abc123", in: b))
        XCTAssertEqual(store.selectedRepoID, b.id)
        XCTAssertEqual(registry.navigator.pending, .init(repoID: b.id, hash: "abc123", windowID: id))
        XCTAssertTrue(registry.navigator.targets(store))
    }
}
