import XCTest
@testable import GituniaCore

final class SecretScanIgnoreTests: XCTestCase {
    func testPrefsDecodeWithoutKeyDefaultsToEmpty() throws {
        let prefs = try JSONDecoder().decode(RepoPrefs.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.secretScanIgnoredPaths, [])
    }

    @MainActor
    func testStoreDropsIgnoredFilesButKeepsPathlessNote() {
        var prefs = RepoPrefs()
        prefs.secretScanIgnoredPaths = ["Tests/Fixture.swift"]
        let store = RepositoryStore(url: URL(fileURLWithPath: "/tmp/none"), prefs: prefs)
        let findings = [
            SecretScanner.Finding(path: "Tests/Fixture.swift", label: "a Slack token"),
            SecretScanner.Finding(path: "config.env", label: "an API key"),
            SecretScanner.Finding(path: "", label: "diff too large to scan"),
        ]
        XCTAssertEqual(store.withoutIgnoredSecrets(findings).map(\.path), ["config.env", ""])
    }
}
