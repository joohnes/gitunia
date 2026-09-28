import XCTest
@testable import GituniaCore

@MainActor
final class WorkspaceFileStoreTests: XCTestCase {
    private func makeStore() throws -> WorkspaceStore {
        let cfg = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        return WorkspaceStore(app: AppConfig(configStore: ConfigStore(fileURL: cfg)), saveDebounce: .milliseconds(10))
    }

    private func repo(named name: String, in dir: URL) async throws -> URL {
        let r = try await TestHelpers.makeTempRepo()
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: r, to: dest)
        return dest
    }

    func testAddFolderOnNonRepoFailsAndAddsNothing() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let plain = try TestHelpers.makeTempDir()
        do { _ = try await store.addRepository(plain); XCTFail("expected error") }
        catch let e as WorkspaceStoreError { XCTAssertTrue(e.localizedDescription.contains("Add Repos in Folder")) }
        XCTAssertTrue(store.file.isEmpty)
        store.stopWatching()
    }

    func testAddRepositoryThenLinkedFolderPicksUpNewRepoOnRescan() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let solo = try await repo(named: "solo", in: try TestHelpers.makeTempDir())
        _ = try await store.addRepository(solo)
        XCTAssertEqual(store.repositories.map(\.repo.name), ["solo"])
        XCTAssertEqual(store.selectedRepoID?.standardizedFileURL, solo.standardizedFileURL)

        let folder = try TestHelpers.makeTempDir()
        _ = try await repo(named: "a", in: folder)
        await store.addFolder(folder)
        XCTAssertEqual(Set(store.repositories.map(\.repo.name)), ["solo", "a"])

        _ = try await repo(named: "b", in: folder)
        await store.refreshAll()
        XCTAssertEqual(Set(store.repositories.map(\.repo.name)), ["solo", "a", "b"])
        store.stopWatching()
    }

    func testInitRepositoryIsAddedAsSingleRepoOnlyOutsideLinkedFolders() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let folder = try TestHelpers.makeTempDir()
        await store.addFolder(folder)

        let freshURL = try await store.initRepository(named: "fresh", in: folder)
        XCTAssertEqual(store.file.repositories, [], "the linked folder already covers it")
        let fresh = try XCTUnwrap(store.repository(atPath: freshURL.path))
        XCTAssertEqual(store.selectedRepoID, fresh.id)

        let looseURL = try await store.initRepository(named: "loose", in: try TestHelpers.makeTempDir())
        XCTAssertEqual(store.file.repositories.count, 1)
        let loose = try XCTUnwrap(store.repository(atPath: looseURL.path))
        XCTAssertEqual(store.selectedRepoID, loose.id)
        store.stopWatching()
    }

    func testRemoveFolderRepoExcludesItAndUndoBringsItBack() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let folder = try TestHelpers.makeTempDir()
        _ = try await repo(named: "a", in: folder)
        _ = try await repo(named: "b", in: folder)
        await store.addFolder(folder)
        let a = try XCTUnwrap(store.repositories.first { $0.repo.name == "a" })
        let removal = try XCTUnwrap(store.remove(a))
        XCTAssertEqual(store.repositories.map(\.repo.name), ["b"])
        await store.refreshAll()
        XCTAssertEqual(store.repositories.map(\.repo.name), ["b"], "a rescan must not bring an excluded repo back")
        await store.undo(removal)
        XCTAssertEqual(Set(store.repositories.map(\.repo.name)), ["a", "b"])
        store.stopWatching()
    }

    /// Local AI only is a privacy guard `CommitBox` reads from the window's own `RepositoryStore`,
    /// so a change in one window must reach every other window showing the same repo.
    func testLocalAIOnlyAndDefaultRemoteReachOtherWindowsWithTheSameRepo() async throws {
        let cfg = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        let app = AppConfig(configStore: ConfigStore(fileURL: cfg))
        let a = WorkspaceStore(app: app), b = WorkspaceStore(app: app)
        await a.openUntitled(); await b.openUntitled()
        let solo = try await repo(named: "solo", in: try TestHelpers.makeTempDir())
        let inA = try await a.addRepository(solo)
        let inB = try await b.addRepository(solo)
        a.setSelectedPath("a-only", for: inA)
        a.setLocalAIOnly(true, for: inA)
        a.setDefaultRemote("upstream", for: inA)
        XCTAssertTrue(inB.repo.localAIOnly)
        XCTAssertEqual(inB.defaultRemote, "upstream")
        XCTAssertNil(inB.restoredSelectedPath, "per-window UI state is not pushed")
        a.stopWatching(); b.stopWatching()
    }

    func testTagsAreWrittenToTheWorkspaceFileNotGlobally() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let solo = try await repo(named: "solo", in: try TestHelpers.makeTempDir())
        let added = try await store.addRepository(solo)
        store.setTags(["core"], for: added)
        store.flushSave()
        let onDisk = try WorkspaceFile.load(from: try XCTUnwrap(store.fileURL))
        XCTAssertEqual(onDisk.tags[added.url.standardizedFileURL.path], ["core"])
        XCTAssertEqual(store.app.config.repos[added.url.path]?.tags ?? [], [])
        XCTAssertEqual(added.repo.tags, ["core"])
        store.stopWatching()
    }

    func testMissingSingleRepoIsListedNotDropped() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let solo = try await repo(named: "solo", in: try TestHelpers.makeTempDir())
        _ = try await store.addRepository(solo)
        try FileManager.default.removeItem(at: solo)
        await store.refreshAll()
        XCTAssertTrue(store.repositories.isEmpty)
        XCTAssertEqual(store.missingPaths, [solo.standardizedFileURL.path])
        store.removeMissing(solo.standardizedFileURL.path)
        XCTAssertEqual(store.missingPaths, [])
        store.stopWatching()
    }

    func testSaveAsWritesRelativePathsAndDeletesUntitled() async throws {
        let store = try makeStore()
        await store.openUntitled()
        let untitled = try XCTUnwrap(store.fileURL)
        let dir = try TestHelpers.makeTempDir()
        let solo = try await repo(named: "solo", in: dir)
        _ = try await store.addRepository(solo)
        store.flushSave()
        let target = dir.appendingPathComponent("team.gitunia-workspace")
        store.app.setWindows([WindowState(workspace: untitled.path)])
        try store.saveAs(target)
        XCTAssertEqual(ConfigStore(fileURL: store.app.configStore.fileURL).loadWithWarning().0.windows.map(\.workspace),
                       [target.standardizedFileURL.path], "the saved window list never points at the deleted untitled file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: untitled.path))
        XCTAssertFalse(store.isUntitled)
        XCTAssertEqual(store.displayName, "team")
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("\"solo\""))
        XCTAssertEqual(store.app.config.recentWorkspaces.first, target.standardizedFileURL.path)
        store.stopWatching()
    }

    func testOpenFileRestoresMembership() async throws {
        let dir = try TestHelpers.makeTempDir()
        let solo = try await repo(named: "solo", in: dir)
        let target = dir.appendingPathComponent("w.gitunia-workspace")
        try WorkspaceFile(repositories: [solo.path]).save(to: target)
        let store = try makeStore()
        try await store.open(fileURL: target)
        XCTAssertEqual(store.repositories.map(\.repo.name), ["solo"])
        store.stopWatching()
    }

    /// Switching workspaces must flush A's debounced save first, or A's last edit is lost.
    func testOpeningAnotherWorkspaceFlushesPendingSave() async throws {
        let cfg = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        let store = WorkspaceStore(app: AppConfig(configStore: ConfigStore(fileURL: cfg)), saveDebounce: .seconds(10))
        await store.openUntitled()
        let urlA = try XCTUnwrap(store.fileURL)
        let fileB = try TestHelpers.makeTempDir().appendingPathComponent("B.gitunia-workspace")
        try WorkspaceFile().save(to: fileB, relativePaths: true)

        let folder = try TestHelpers.makeTempDir()
        await store.addFolder(folder)
        try await store.open(fileURL: fileB)

        let onDisk = try WorkspaceFile.load(from: urlA)
        XCTAssertEqual(onDisk.folders.map(\.path), [WorkspaceFile.standardize(folder.path)])
        store.stopWatching()
    }
}
