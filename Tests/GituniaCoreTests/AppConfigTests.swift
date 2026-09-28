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

    func testRecentsSkipUntitledDedupeAndCapAtTen() throws {
        let (app, _) = try makeApp()
        app.noteRecent(app.newUntitledURL())
        XCTAssertEqual(app.config.recentWorkspaces, [])
        for i in 0..<12 { app.noteRecent(URL(fileURLWithPath: "/w/\(i).gitunia-workspace")) }
        app.noteRecent(URL(fileURLWithPath: "/w/3.gitunia-workspace"))
        XCTAssertEqual(app.config.recentWorkspaces.count, 10)
        XCTAssertEqual(app.config.recentWorkspaces.first, "/w/3.gitunia-workspace")
        XCTAssertEqual(Set(app.config.recentWorkspaces).count, 10)
    }

    func testPrefsRoundTripThroughDisk() throws {
        let (app, url) = try makeApp()
        app.updatePrefs(for: "/r") { $0.localAIOnly = true }
        XCTAssertTrue(app.prefs(for: "/r").localAIOnly)
        XCTAssertEqual(ConfigStore(fileURL: url).loadWithWarning().0.repos["/r"]?.localAIOnly, true)
    }

    func testWindowsRoundTrip() throws {
        let (app, url) = try makeApp()
        let w = WindowState(workspace: "/a.gitunia-workspace", selectedRepo: "/r")
        app.setWindows([w])
        XCTAssertEqual(ConfigStore(fileURL: url).loadWithWarning().0.windows, [w])
    }

    /// A failed save of the global file is reported once (not on every later save that fails the
    /// same way), and a successful save re-arms it.
    func testPersistFailureIsReportedOnceUntilASaveSucceeds() throws {
        let dir = try TestHelpers.makeTempDir()
        let blocker = dir.appendingPathComponent("blocker")
        try "".write(to: blocker, atomically: true, encoding: .utf8)   // a file where a directory must go
        let app = AppConfig(configStore: ConfigStore(fileURL: blocker.appendingPathComponent("workspace.json")))

        app.setLastRepoParent(dir)
        XCTAssertNotNil(app.persistError)
        app.dismissPersistError()
        app.setLastRepoParent(dir)
        XCTAssertNil(app.persistError, "the same failure again must not re-toast")

        try FileManager.default.removeItem(at: blocker)
        app.setLastRepoParent(dir)
        XCTAssertNil(app.persistError)
        try "".write(to: blocker.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocker.path) }
        app.setLastRepoParent(blocker)
        XCTAssertNotNil(app.persistError, "after a success, a new failure is reported again")
    }
}
