import XCTest
@testable import GituniaCore

@MainActor
final class AppConfigTests: XCTestCase {
    private func makeApp() throws -> (AppConfig, URL) {
        let url = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        return (AppConfig(configStore: ConfigStore(fileURL: url)), url)
    }

    func testMigrateIfNeededWritesUntitledFileAndOneWindow() throws {
        let (_, url) = try makeApp()
        var old = WorkspaceConfig()
        old.workspacePath = "/ws"
        old.repos["/ws/a"] = RepoPrefs(tags: ["core"])
        try ConfigStore(fileURL: url).save(old)

        let app = AppConfig(configStore: ConfigStore(fileURL: url))
        let fileURL = try XCTUnwrap(app.migrateIfNeeded())
        XCTAssertTrue(app.isUntitled(fileURL))
        XCTAssertEqual(try WorkspaceFile.load(from: fileURL).folders.map(\.path), ["/ws"])
        XCTAssertEqual(app.config.windows.map(\.workspace), [fileURL.path])
        let reloaded = ConfigStore(fileURL: url).loadWithWarning().0
        XCTAssertNil(reloaded.workspacePath)
        XCTAssertEqual(reloaded.windows.count, 1)
        XCTAssertNil(app.migrateIfNeeded(), "second run is a no-op")
    }

    /// A failed migration must say so and leave `workspacePath` for the next launch to retry —
    /// even after that launch saved a window list.
    func testFailedMigrationWarnsKeepsTheFolderAndRetriesLater() throws {
        let (_, url) = try makeApp()
        var old = WorkspaceConfig()
        old.workspacePath = "/ws"
        try ConfigStore(fileURL: url).save(old)
        let blocker = url.deletingLastPathComponent().appendingPathComponent("Untitled")
        try Data().write(to: blocker)   // a file where the Untitled directory must go

        let app = AppConfig(configStore: ConfigStore(fileURL: url))
        XCTAssertNil(app.migrateIfNeeded())
        XCTAssertNotNil(app.loadWarning)
        XCTAssertEqual(ConfigStore(fileURL: url).loadWithWarning().0.workspacePath, "/ws")
        app.setWindows([WindowState(workspace: app.newUntitledURL().path)])

        try FileManager.default.removeItem(at: blocker)
        let next = AppConfig(configStore: ConfigStore(fileURL: url))
        let fileURL = try XCTUnwrap(next.migrateIfNeeded())
        XCTAssertEqual(try WorkspaceFile.load(from: fileURL).folders.map(\.path), ["/ws"])
        XCTAssertTrue(next.config.windows.contains { $0.workspace == fileURL.path })
        XCTAssertNil(next.migrateIfNeeded(), "a successful migration runs once")
    }
}
