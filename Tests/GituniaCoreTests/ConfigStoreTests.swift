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

    func testPartialJSONKeepsDefaultsForMissingKeys() throws {
        let dir = try TestHelpers.makeTempDir()
        let fileURL = dir.appendingPathComponent("workspace.json")
        // With no `settings` key, and with an empty one (no agentProfile key inside).
        for json in [#"{"workspacePath":"/tmp/ws","repos":{"/tmp/ws/a":{"tags":["x"]}}}"#,
                     #"{"workspacePath":"/tmp/ws","repos":{"/tmp/ws/a":{"tags":["x"]}},"settings":{}}"#] {
            try json.write(to: fileURL, atomically: true, encoding: .utf8)
            let store = ConfigStore(fileURL: fileURL)

            let (cfg, warning) = store.loadWithWarning()

            XCTAssertNil(warning, json)
            XCTAssertEqual(cfg.workspacePath, "/tmp/ws", json)
            XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.tags, ["x"], json)
            XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.localAIOnly, false, json)
            XCTAssertEqual(cfg.settings, AppSettings(), json)
            XCTAssertEqual(cfg.settings.agentProfile, AgentProfile(), json)
            XCTAssertNil(cfg.repos["/tmp/ws/a"]?.selectedPath, json)
            XCTAssertNil(cfg.repos["/tmp/ws/a"]?.commitDraft, json)
            XCTAssertNil(cfg.repos["/tmp/ws/a"]?.agentPatterns, json)
            XCTAssertEqual(cfg.repos["/tmp/ws/a"]?.fetchCadence, .normal, json)
        }
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

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("workspace.json.corrupt-") })
        // `load()` (used by `WorkspaceStore.init`) still degrades to the same safe defaults.
        XCTAssertEqual(store.loadWithWarning().0, WorkspaceConfig())
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
}
