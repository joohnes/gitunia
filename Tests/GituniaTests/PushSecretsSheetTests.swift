import XCTest
import SwiftUI
@testable import Gitunia
@testable import GituniaCore

final class PushSecretsSheetTests: XCTestCase {
    private let findings = [
        SecretScanner.Finding(path: "Tests/A.swift", label: "an AWS access key ID", commitHash: "e68105fbd437", commitSubject: "feat"),
        SecretScanner.Finding(path: "Tests/A.swift", label: "a hardcoded password/secret/token", commitHash: "e68105fbd437", commitSubject: "feat"),
        SecretScanner.Finding(path: "Tests/B.swift", label: "a private key", commitHash: "cb32b4ace927", commitSubject: "initial"),
        SecretScanner.Finding(path: "Tests/A.swift", label: "an AWS access key ID", commitHash: "cb32b4ace927", commitSubject: "initial"),
    ]

    func testRowsGroupByFileKeepingLabelsAndCommits() {
        let rows = PushSecretsSheet.rows(findings)
        XCTAssertEqual(rows.map(\.path), ["Tests/A.swift", "Tests/B.swift"])
        XCTAssertEqual(rows[0].labels, ["an AWS access key ID", "a hardcoded password/secret/token"])
        XCTAssertEqual(rows[0].commits, ["e68105f", "cb32b4a"])
    }
}

final class PushSecretsSheetRenderTests: RenderTestCase {
    func testRender_pushSecretsSheet() throws {
        let findings = [
            SecretScanner.Finding(path: "Tests/GituniaCoreTests/PushScanTests.swift", label: "an AWS access key ID", commitHash: "e68105fbd437", commitSubject: "feat"),
            SecretScanner.Finding(path: "Tests/GituniaCoreTests/SecretScannerTests.swift", label: "a Slack token", commitHash: "cb32b4ace927", commitSubject: "initial"),
            SecretScanner.Finding(path: "Tests/GituniaTests/DiffFixesRenderTests.swift", label: "a private key", commitHash: "cb32b4ace927", commitSubject: "initial"),
        ]
        let view = PushSecretsSheet(repoName: "gitunia", findings: findings, onIgnore: { _ in }, onPush: {}, onCancel: {})
        print("Rendered: \(try renderPlainPNG(view, name: "push-secrets-sheet", size: CGSize(width: 560, height: 360)))")
    }
}

/// Settings → Updates after a check that found this build up to date.
final class SettingsUpdatesRenderTests: RenderTestCase {
    func testRender_settingsUpdatesUpToDate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-settings-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppConfig(configStore: ConfigStore(fileURL: dir.appendingPathComponent("workspace.json")))
        let json = #"{"tag_name": "v0.2.40", "html_url": "https://example.com", "draft": false, "prerelease": false, "assets": []}"#
        let updates = UpdateCoordinator(app: app, toasts: ToastCenter(), checker: UpdateChecker(fetch: { _ in Data(json.utf8) }),
                                        bundleVersion: "0.2.40", hasBundle: true)
        await updates.checkIfDue(force: true)?.value
        let view = ScrollView { SettingsView(app: app, updates: updates) }
        print("Rendered: \(try renderPlainPNG(view, name: "settings-updates", size: CGSize(width: 500, height: 1500)))")
    }
}
