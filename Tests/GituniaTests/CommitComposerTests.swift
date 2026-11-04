import XCTest
@testable import Gitunia
@testable import GituniaCore

@MainActor
final class CommitComposerTests: XCTestCase {
    /// Each repo keeps its own draft (the box used to carry text across a switch), and edits
    /// reach the repo's persisted draft even when that repo isn't the one on screen.
    func testDraftIsPerRepoAndPersisted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-composer-\(UUID().uuidString)")
        let workspace = WorkspaceStore(app: AppConfig(configStore: ConfigStore(fileURL: root.appendingPathComponent("workspace.json"))))
        await workspace.openUntitled()
        let a = try await workspace.addRepository(try await TestRepo.make())
        let b = try await workspace.addRepository(try await TestRepo.make())

        CommitComposer.for(a, in: workspace).title = "feat: a"
        XCTAssertEqual(CommitComposer.for(b, in: workspace).title, "")
        XCTAssertTrue(CommitComposer.for(a, in: workspace) === CommitComposer.for(a, in: workspace))

        CommitComposer.for(b, in: workspace).body = "generated while A was shown"
        XCTAssertEqual(a.restoredDraft?.title, "feat: a")
        XCTAssertEqual(b.restoredDraft?.body, "generated while A was shown")
        workspace.stopWatching()
    }

    /// The same repository open in two workspace windows keeps one draft per window.
    func testDraftIsPerWindow() async throws {
        let repoURL = try await TestRepo.make()
        func makeWorkspace() async throws -> (WorkspaceStore, RepositoryStore) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-composer-\(UUID().uuidString)")
            let workspace = WorkspaceStore(app: AppConfig(configStore: ConfigStore(fileURL: root.appendingPathComponent("workspace.json"))))
            await workspace.openUntitled()
            return (workspace, try await workspace.addRepository(repoURL))
        }
        let (first, inFirst) = try await makeWorkspace()
        let (second, inSecond) = try await makeWorkspace()

        CommitComposer.for(inFirst, in: first).title = "feat: first window"
        XCTAssertEqual(CommitComposer.for(inSecond, in: second).title, "")
        XCTAssertFalse(CommitComposer.for(inFirst, in: first) === CommitComposer.for(inSecond, in: second))
        first.stopWatching()
        second.stopWatching()
    }
}
