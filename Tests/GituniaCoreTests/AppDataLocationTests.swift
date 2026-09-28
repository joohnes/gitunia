import XCTest
@testable import GituniaCore

final class AppDataLocationTests: XCTestCase {
    private let fm = FileManager.default

    private func dirs() throws -> (legacy: URL, target: URL) {
        let root = try TestHelpers.makeTempDir()
        let legacy = root.appendingPathComponent("AppSupport/Gitunia")
        try fm.createDirectory(at: legacy.appendingPathComponent("Untitled"), withIntermediateDirectories: true)
        return (legacy, root.appendingPathComponent("Documents/Gitunia"))
    }

    func testMovesFilesAndUntitledFolderAndLeavesNote() throws {
        let (legacy, target) = try dirs()
        try "{}".write(to: legacy.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        try "[]".write(to: legacy.appendingPathComponent("activity.json"), atomically: true, encoding: .utf8)
        try "x".write(to: legacy.appendingPathComponent("Untitled/a.gitunia-workspace"), atomically: true, encoding: .utf8)

        let result = AppDataLocation.migrateIfNeeded(from: legacy, to: target)

        XCTAssertNil(result.error)
        XCTAssertEqual(Set(result.moved), ["workspace.json", "activity.json", "Untitled"])
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("activity.json").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Untitled/a.gitunia-workspace").path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.appendingPathComponent("workspace.json").path))
        let note = try String(contentsOf: legacy.appendingPathComponent("MIGRATED.txt"), encoding: .utf8)
        XCTAssertTrue(note.contains(target.path))
    }

    func testSkipsWhenTargetAlreadyHasWorkspaceJSON() throws {
        let (legacy, target) = try dirs()
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: legacy.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        try "new".write(to: target.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

        let result = AppDataLocation.migrateIfNeeded(from: legacy, to: target)

        XCTAssertEqual(result, AppDataLocation.MigrationResult())
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("workspace.json"), encoding: .utf8), "new")
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("workspace.json").path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.appendingPathComponent("MIGRATED.txt").path))
    }

    func testNeverOverwritesExistingTargetFile() throws {
        let (legacy, target) = try dirs()
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: legacy.appendingPathComponent("activity.json"), atomically: true, encoding: .utf8)
        try "new".write(to: target.appendingPathComponent("activity.json"), atomically: true, encoding: .utf8)

        let result = AppDataLocation.migrateIfNeeded(from: legacy, to: target)

        XCTAssertEqual(result.skipped, ["activity.json"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("activity.json"), encoding: .utf8), "new")
    }

    @MainActor
    func testRewritesUntitledPathsInWindowsAndRecents() throws {
        let (legacy, target) = try dirs()
        let oldUntitled = legacy.standardizedFileURL.path + "/Untitled/a.gitunia-workspace"
        let json = """
        {"windows":[{"id":"\(UUID().uuidString)","workspace":"\(oldUntitled)"},
                    {"id":"\(UUID().uuidString)","workspace":"/Users/me/Work.gitunia-workspace"}],
         "recentWorkspaces":["\(oldUntitled)","/Users/me/Work.gitunia-workspace"]}
        """
        try json.write(to: legacy.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

        AppDataLocation.migrateIfNeeded(from: legacy, to: target)

        let store = ConfigStore(fileURL: target.appendingPathComponent("workspace.json"))
        let cfg = store.loadWithWarning().0
        let newUntitled = target.standardizedFileURL.path + "/Untitled/a.gitunia-workspace"
        XCTAssertEqual(cfg.windows.map(\.workspace), [newUntitled, "/Users/me/Work.gitunia-workspace"])
        XCTAssertEqual(cfg.recentWorkspaces, [newUntitled, "/Users/me/Work.gitunia-workspace"])
        // The rewritten path is what `AppConfig.isUntitled` recognizes for the new location.
        let app = AppConfig(configStore: store)
        XCTAssertTrue(app.isUntitled(URL(fileURLWithPath: newUntitled)))
    }

    // MARK: - A4: writableDirectory

    func testWritableDirectoryFallsBackWhenPreferredIsDenied() throws {
        let root = try TestHelpers.makeTempDir()
        // A parent with no write permission stands in for a TCC-denied ~/Documents: creating
        // "Gitunia" inside it fails exactly like Documents access being refused would.
        let deniedParent = root.appendingPathComponent("Denied")
        try fm.createDirectory(at: deniedParent, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deniedParent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deniedParent.path) }
        let preferred = deniedParent.appendingPathComponent("Gitunia")
        let fallback = root.appendingPathComponent("AppSupport/Gitunia")
        try XCTSkipIf(fm.isWritableFile(atPath: deniedParent.path), "running as root; can't deny write access")

        XCTAssertEqual(AppDataLocation.writableDirectory(preferred: preferred, fallback: fallback), fallback)
    }

    // MARK: - B11: cleanupTemp

    func testCleanupTempRemovesOnlyOldMatchingDirs() throws {
        let root = try TestHelpers.makeTempDir()
        let old = root.appendingPathComponent("gitunia-rebase-old")
        let new = root.appendingPathComponent("gitunia-rebase-new")
        let unrelated = root.appendingPathComponent("gitunia-tidy-other")
        for dir in [old, new, unrelated] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: old.path)

        AppDataLocation.cleanupTemp(prefix: "gitunia-rebase-", olderThan: 24 * 60 * 60, in: root)

        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: new.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    func testReportsErrorWhenLegacyIsUnreadable() throws {
        let (legacy, target) = try dirs()
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: legacy.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.path) }
        try XCTSkipIf(fm.isReadableFile(atPath: legacy.path), "running as root; can't make the folder unreadable")

        let result = AppDataLocation.migrateIfNeeded(from: legacy, to: target)

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.moved.isEmpty)
    }

    func testChooseRejectsNestedFolderAndQueuesMoveOnce() throws {
        let defaults = UserDefaults.standard
        defer { [AppDataLocation.customDirectoryKey, AppDataLocation.pendingMoveKey].forEach(defaults.removeObject) }
        let root = try TestHelpers.makeTempDir()
        let current = root.appendingPathComponent("Old"), new = root.appendingPathComponent("New")

        XCTAssertNotNil(AppDataLocation.choose(current.appendingPathComponent("sub"), current: current))
        XCTAssertNil(defaults.string(forKey: AppDataLocation.customDirectoryKey))

        XCTAssertNil(AppDataLocation.choose(new, current: current))
        XCTAssertEqual(AppDataLocation.directory.path, new.standardizedFileURL.path)
        XCTAssertEqual(AppDataLocation.takePendingMove()?.path, current.standardizedFileURL.path)
        XCTAssertNil(AppDataLocation.takePendingMove())
    }
}
