import XCTest
@testable import Gitunia
import GituniaCore

@MainActor
final class WorkspaceRegistryTests: XCTestCase {
    private func makeRegistry() throws -> (WorkspaceRegistry, URL) {
        let cfg = try XCTUnwrap(FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-registry-\(UUID().uuidString)/workspace.json"))
        return (WorkspaceRegistry(app: AppConfig(configStore: ConfigStore(fileURL: cfg))), cfg)
    }

    private func workspaceFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-reg-ws-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("w.gitunia-workspace")
        try WorkspaceFile().save(to: url)
        return url
    }

    func testOpeningTheSameFileTwiceFocusesTheExistingWindow() async throws {
        let (registry, _) = try makeRegistry()
        var opened: [UUID] = []
        registry.openWindowAction = { opened.append($0) }
        let file = try workspaceFile()
        try await registry.open(file, from: nil)
        try await registry.open(file, from: nil)
        XCTAssertEqual(registry.stores.count, 1)
        XCTAssertEqual(Set(opened).count, 1, "second open re-targets the same window id")
    }

    func testWindowsPersistAndTerminationDoesNotEmptyThem() async throws {
        let (registry, cfg) = try makeRegistry()
        registry.openWindowAction = { _ in }
        try await registry.open(try workspaceFile(), from: nil)
        try await registry.open(try workspaceFile(), from: nil)
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows.count, 2)

        registry.isTerminating = true
        for id in registry.windowOrder { registry.windowClosed(id) }
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows.count, 2)
    }

    func testNormalCloseRemovesWindowAndEmptyUntitledFile() async throws {
        let (registry, cfg) = try makeRegistry()
        registry.openWindowAction = { _ in }
        registry.newWindow()
        let id = try XCTUnwrap(registry.windowOrder.first)
        let store = await registry.attachWindow(id)
        let untitled = try XCTUnwrap(store.fileURL)
        registry.windowClosed(id)
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: untitled.path))
    }

    func testLaunchPlanSkipsMissingFilesAndMigratesOldFolder() throws {
        let (_, cfg) = try makeRegistry()
        var old = WorkspaceConfig()
        old.workspacePath = "/tmp/some-folder"
        try ConfigStore(fileURL: cfg).save(old)
        let fresh = WorkspaceRegistry(app: AppConfig(configStore: ConfigStore(fileURL: cfg)))
        let plan = fresh.launchPlan()
        XCTAssertEqual(plan.windows.count, 1)
        XCTAssertTrue(fresh.app.isUntitled(URL(fileURLWithPath: plan.windows[0].workspace)))

        var withMissing = ConfigStore(fileURL: cfg).loadWithWarning().0
        withMissing.windows.append(WindowState(workspace: "/nope/gone.gitunia-workspace"))
        try ConfigStore(fileURL: cfg).save(withMissing)
        let again = WorkspaceRegistry(app: AppConfig(configStore: ConfigStore(fileURL: cfg)))
        let plan2 = again.launchPlan()
        XCTAssertEqual(plan2.windows.count, 1)
        XCTAssertEqual(plan2.notFound, ["gone"])
    }

    func testUnreadableSavedFileFallsBackToUntitledAndRecordsTheError() async throws {
        let (_, cfg) = try makeRegistry()
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-reg-bad-\(UUID().uuidString).gitunia-workspace")
        try Data("not json".utf8).write(to: bad)
        var saved = ConfigStore(fileURL: cfg).loadWithWarning().0
        saved.windows = [WindowState(workspace: bad.path)]
        try ConfigStore(fileURL: cfg).save(saved)
        let fresh = WorkspaceRegistry(app: AppConfig(configStore: ConfigStore(fileURL: cfg)))
        let plan = fresh.launchPlan()
        let store = await fresh.attachWindow(plan.windows[0].id)
        XCTAssertTrue(store.isUntitled)
        XCTAssertNotNil(fresh.takeAttachError(plan.windows[0].id))
        XCTAssertNil(fresh.takeAttachError(plan.windows[0].id), "reported once")
    }

    private func registryWithSavedWindows(_ count: Int) throws -> (WorkspaceRegistry, URL) {
        let (_, cfg) = try makeRegistry()
        var saved = ConfigStore(fileURL: cfg).loadWithWarning().0
        saved.windows = try (0..<count).map { _ in WindowState(workspace: try workspaceFile().path) }
        try ConfigStore(fileURL: cfg).save(saved)
        return (WorkspaceRegistry(app: AppConfig(configStore: ConfigStore(fileURL: cfg))), cfg)
    }

    func testQuitBeforeEveryWindowAttachedKeepsTheWholeSavedList() async throws {
        let (registry, cfg) = try registryWithSavedWindows(2)
        let savedIDs = ConfigStore(fileURL: cfg).loadWithWarning().0.windows.map(\.id)
        let plan = registry.launchPlan()
        _ = await registry.attachWindow(plan.windows[0].id)
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows.map(\.id), savedIDs)
    }

    func testLaunchCoordinatorSkipsAttachedWindowsAndOpensTheRestOnce() async throws {
        let (registry, _) = try registryWithSavedWindows(3)
        var opened: [UUID] = []
        registry.openWindowAction = { opened.append($0) }
        let launch = LaunchCoordinator()
        launch.ensurePlan(registry: registry)
        let ids = registry.windowOrder
        _ = await registry.attachWindow(ids[0])   // macOS restored this one by itself
        let claimed = launch.claimFirstWindow(registry: registry)
        XCTAssertEqual(claimed, ids[1])
        _ = await registry.attachWindow(claimed)
        launch.openRemaining(registry: registry, except: claimed)
        launch.openRemaining(registry: registry, except: claimed)
        XCTAssertEqual(opened, [ids[2]])
    }

    /// Closing a window during its first load used to leave a store that went on watching and
    /// auto-fetching after the window was gone.
    func testClosingAWindowWhileItIsStillLoadingLeavesNothingBehind() async throws {
        let (registry, cfg) = try makeRegistry()
        registry.openWindowAction = { _ in }
        registry.newWindow()
        let id = try XCTUnwrap(registry.windowOrder.first)
        let attach = Task { await registry.attachWindow(id) }
        while registry.store(for: id) == nil { await Task.yield() }
        registry.windowClosed(id)
        let store = await attach.value
        XCTAssertNil(registry.store(for: id))
        XCTAssertFalse(registry.windowOrder.contains(id))
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL).path))
    }

    func testDiscardUntitledDeletesItsFileAndForgetsTheWindow() async throws {
        let (registry, cfg) = try makeRegistry()
        registry.openWindowAction = { _ in }
        registry.newWindow()
        let id = try XCTUnwrap(registry.windowOrder.first)
        let store = await registry.attachWindow(id)
        await store.addFolder(FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-reg-folder-\(UUID().uuidString)"))
        let untitled = try XCTUnwrap(store.fileURL)
        store.flushSave()
        XCTAssertTrue(FileManager.default.fileExists(atPath: untitled.path))
        registry.discardUntitled(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: untitled.path))
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows, [])
    }

    func testOpeningFromAnEmptyUntitledWindowReusesIt() async throws {
        let (registry, cfg) = try makeRegistry()
        var opened: [UUID] = []
        registry.openWindowAction = { opened.append($0) }
        registry.newWindow()
        let id = try XCTUnwrap(registry.windowOrder.first)
        opened = []
        let store = await registry.attachWindow(id)
        let untitled = try XCTUnwrap(store.fileURL)
        let file = try workspaceFile()
        try await registry.open(file, from: id)
        XCTAssertTrue(registry.store(for: id) === store)
        XCTAssertEqual(store.fileURL, file.standardizedFileURL)
        XCTAssertEqual(registry.stores.count, 1)
        XCTAssertEqual(opened, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: untitled.path))
        XCTAssertEqual(ConfigStore(fileURL: cfg).loadWithWarning().0.windows.map(\.workspace), [file.standardizedFileURL.path])
        store.stopWatching()
    }

    /// "Don't Save" deletes the untitled file; a lingering Undo toast must not write it back.
    func testUndoAfterTheWorkspaceWasDiscardedDoesNothing() async throws {
        let (registry, _) = try makeRegistry()
        registry.openWindowAction = { _ in }
        registry.newWindow()
        let id = try XCTUnwrap(registry.windowOrder.first)
        let store = await registry.attachWindow(id)
        let untitled = store.fileURL
        registry.discardUntitled(id)
        await WorkspaceActions.undoRemoval(.single("/gone/repo", excludedIn: []), in: store, ifStillAt: untitled)
        XCTAssertEqual(store.file.repositories, [])
        store.flushSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(untitled).path))
    }

    func testWindowSubtitleIsRepoNameAndBranch() {
        let url = URL(fileURLWithPath: "/x/gitunia")
        XCTAssertEqual(ContentView.windowSubtitle(Repository(id: url, branch: "main")), "gitunia — main")
        XCTAssertEqual(ContentView.windowSubtitle(Repository(id: url)), "gitunia")
    }

    func testCloseAlertCountsArePluralised() {
        XCTAssertEqual(CloseDelegateProxy.count(1, "repository", "repositories"), "1 repository")
        XCTAssertEqual(CloseDelegateProxy.count(2, "linked folder", "linked folders"), "2 linked folders")
    }
}
