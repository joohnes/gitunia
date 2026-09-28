import XCTest
@testable import GituniaCore

final class ConfigStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = try TestHelpers.makeTempDir()
        let store = ConfigStore(fileURL: dir.appendingPathComponent("workspace.json"))
        var cfg = WorkspaceConfig()
        cfg.workspacePath = "/tmp/ws"
        cfg.repos["/tmp/ws/a"] = RepoPrefs(tags: ["work"], localAIOnly: true)
        cfg.settings.ollamaModel = "llama3.1"
        try store.save(cfg)
        XCTAssertEqual(store.loadWithWarning().0, cfg)
    }

    func testMissingFileGivesDefaults() throws {
        let dir = try TestHelpers.makeTempDir()
        let store = ConfigStore(fileURL: dir.appendingPathComponent("nope.json"))
        XCTAssertEqual(store.loadWithWarning().0, WorkspaceConfig())
    }

    func testDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.aiProvider, .claudeCLI)
        XCTAssertEqual(s.diffCharLimit, 8000)
        XCTAssertNil(s.editorBundleID)
    }

    func testAppearanceAndAutoFetchRoundTrip() throws {
        let dir = try TestHelpers.makeTempDir()
        let store = ConfigStore(fileURL: dir.appendingPathComponent("workspace.json"))
        var cfg = WorkspaceConfig()
        cfg.settings.appearance = .dark
        cfg.settings.autoFetchMinutes = 30
        try store.save(cfg)
        XCTAssertEqual(store.loadWithWarning().0, cfg)
    }

    func testDecodingWithoutAppearanceOrAutoFetchYieldsDefaults() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        let json = #"{"workspacePath":"/tmp/ws","repos":{},"settings":{"ollamaModel":"llama3.1"}}"#
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)

        let cfg = store.loadWithWarning().0

        XCTAssertEqual(cfg.settings.appearance, .system)
        XCTAssertEqual(cfg.settings.autoFetchMinutes, 15)
    }

    func testPartialJSONKeepsDefaultsForMissingKeys() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        let json = #"{"workspacePath":"/tmp/ws","repos":{"/tmp/ws/a":{"tags":["x"]}}}"#
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)

        let cfg = store.loadWithWarning().0

        XCTAssertEqual(cfg.workspacePath, "/tmp/ws")
        XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.tags, ["x"])
        XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.localAIOnly, false)
        XCTAssertEqual(cfg.settings, AppSettings())
        XCTAssertNil(cfg.repos["/tmp/ws/a"]?.selectedPath)
        XCTAssertNil(cfg.repos["/tmp/ws/a"]?.commitDraft)
    }

    func testSelectedPathAndCommitDraftRoundTrip() throws {
        let dir = try TestHelpers.makeTempDir()
        let store = ConfigStore(fileURL: dir.appendingPathComponent("workspace.json"))
        var cfg = WorkspaceConfig()
        cfg.repos["/tmp/ws/a"] = RepoPrefs(
            tags: ["work"],
            selectedPath: "src/main.swift",
            commitDraft: CommitMessage(title: "wip", body: "details")
        )
        try store.save(cfg)
        XCTAssertEqual(store.loadWithWarning().0, cfg)
    }

    // MARK: - L8: corrupt file handling

    func testCorruptFileIsBackedUpAndLoadReturnsDefaultsWithWarning() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        try "not json at all { [[[".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)

        let (cfg, warning) = store.loadWithWarning()

        XCTAssertEqual(cfg, WorkspaceConfig())
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("Local AI only") == true)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("workspace.json.corrupt-") })
        // `load()` (used by `WorkspaceStore.init`) still degrades to the same safe defaults.
        XCTAssertEqual(store.loadWithWarning().0, WorkspaceConfig())
    }

    func testWellFormedFileNeverProducesAWarningOrBackup() throws {
        let dir = try TestHelpers.makeTempDir()
        let store = ConfigStore(fileURL: dir.appendingPathComponent("workspace.json"))
        try store.save(WorkspaceConfig())

        let (_, warning) = store.loadWithWarning()

        XCTAssertNil(warning)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(siblings.contains { $0.contains(".corrupt-") })
    }

    func testWorkspaceStoreSurfacesConfigLoadWarningFromACorruptFile() async throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        try "{ broken".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = await WorkspaceStore(configStore: ConfigStore(fileURL: fileURL))
        let warning = await store.configLoadWarning
        XCTAssertNotNil(warning)
        await store.dismissConfigLoadWarning()
        let cleared = await store.configLoadWarning
        XCTAssertNil(cleared)
    }

    // MARK: - D20: malformed AgentProfile/agentPatterns/fetchCadence surface, missing keys default

    func testMalformedAgentProfileIsTreatedAsCorruptRatherThanSilentlyDefaulted() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        try #"{"settings":{"agentProfile":42}}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)

        let (cfg, warning) = store.loadWithWarning()

        XCTAssertEqual(cfg, WorkspaceConfig(), "falls back to defaults, same as any other corrupt file")
        XCTAssertNotNil(warning)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("workspace.json.corrupt-") })
    }

    func testMissingAgentProfilePatternsAndCadenceKeysStillDefault() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        let json = #"{"repos":{"/tmp/ws/a":{"tags":["x"]}},"settings":{}}"#
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)

        let (cfg, warning) = store.loadWithWarning()

        XCTAssertNil(warning)
        XCTAssertEqual(cfg.settings.agentProfile, AgentProfile())
        XCTAssertNil(cfg.repos["/tmp/ws/a"]?.agentPatterns)
        XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.fetchCadence, .normal)
    }

    func testDecodingWorkspaceJSONWithoutSelectedPathOrDraftYieldsNil() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        // Predates B2: no selectedPath/commitDraft keys at all.
        let json = #"{"workspacePath":"/tmp/ws","repos":{"/tmp/ws/a":{"tags":["x"],"localAIOnly":true}},"settings":{}}"#
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)

        let cfg = store.loadWithWarning().0

        XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.tags, ["x"])
        XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.localAIOnly, true)
        XCTAssertNil(cfg.repos["/tmp/ws/a"]?.selectedPath)
        XCTAssertNil(cfg.repos["/tmp/ws/a"]?.commitDraft)
    }
}
