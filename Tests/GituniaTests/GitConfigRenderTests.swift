import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `GitConfigSheet` with injected values (local / global / system / unset
/// mixed) — same harness as `RemotesRenderTests`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter GitConfigRenderTests
@MainActor
final class GitConfigRenderTests: RenderTestCase {
    private let values: [ConfigValue] = [
        ConfigValue(key: "user.name", value: "Jan Kowalski", scope: .global, inherited: "Jan Kowalski"),
        ConfigValue(key: "user.email", value: "agent@acme.dev", scope: .local, inherited: "jan@example.com"),
        ConfigValue(key: "pull.rebase", value: "true", scope: .global, inherited: "true"),
        ConfigValue(key: "push.default", value: "current", scope: .local, inherited: "simple"),
        ConfigValue(key: "push.autoSetupRemote", value: "true", scope: .local),
        ConfigValue(key: "fetch.prune", value: nil, scope: .unset),
        ConfigValue(key: "merge.conflictStyle", value: "zdiff3", scope: .global, inherited: "zdiff3"),
        ConfigValue(key: "init.defaultBranch", value: "main", scope: .system, inherited: "main"),
    ]

    func testRender_01_sheet() async throws {
        let store = RepositoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("app"))
        let sheet = GitConfigSheet(repo: store, initialValues: values)
        print("Rendered:", try await renderPNG(sheet, name: "gitconfig-01-sheet", size: CGSize(width: 560, height: 1500)))
    }

    func testRender_02_sheetDark() async throws {
        let store = RepositoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("app"))
        let sheet = GitConfigSheet(repo: store, initialValues: values)
        print("Rendered:", try await renderPNG(sheet, name: "gitconfig-02-sheet-dark", size: CGSize(width: 560, height: 640), colorScheme: .dark))
    }
}
