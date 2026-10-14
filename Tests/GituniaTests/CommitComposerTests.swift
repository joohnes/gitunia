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
}
