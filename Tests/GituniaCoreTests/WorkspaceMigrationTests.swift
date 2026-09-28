import XCTest
@testable import GituniaCore

final class WorkspaceMigrationTests: XCTestCase {
    func testMovesFolderAndItsTagsIntoWorkspaceFile() {
        var config = WorkspaceConfig()
        config.workspacePath = "/ws"
        config.repos["/ws/a"] = RepoPrefs(tags: ["core"], localAIOnly: true)
        config.repos["/elsewhere/b"] = RepoPrefs(tags: ["keep"])
        let migrated = try! XCTUnwrap(WorkspaceMigration.migrate(config))
        XCTAssertEqual(migrated.file, WorkspaceFile(folders: [.init(path: "/ws")], tags: ["/ws/a": ["core"]]))
        XCTAssertNil(migrated.config.workspacePath)
        XCTAssertEqual(migrated.config.repos["/ws/a"]?.tags, [])
        XCTAssertEqual(migrated.config.repos["/ws/a"]?.localAIOnly, true)
        XCTAssertEqual(migrated.config.repos["/elsewhere/b"]?.tags, ["keep"])
    }

    func testNothingToMigrate() {
        XCTAssertNil(WorkspaceMigration.migrate(WorkspaceConfig()))
    }

    /// A failed earlier attempt may have saved windows already; the folder must still migrate.
    func testMigratesEvenWithSavedWindows() {
        var config = WorkspaceConfig()
        config.workspacePath = "/ws"
        config.windows = [WindowState(workspace: "/x.gitunia-workspace")]
        XCTAssertNotNil(WorkspaceMigration.migrate(config))
    }

    func testTrailingSlashOnOldFolderStillMatchesItsRepos() {
        var config = WorkspaceConfig()
        config.workspacePath = "/ws/"
        config.repos["/ws/a"] = RepoPrefs(tags: ["core"])
        let migrated = try! XCTUnwrap(WorkspaceMigration.migrate(config))
        XCTAssertEqual(migrated.file, WorkspaceFile(folders: [.init(path: "/ws")], tags: ["/ws/a": ["core"]]))
    }
}
