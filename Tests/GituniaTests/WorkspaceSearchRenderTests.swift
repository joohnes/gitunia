import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `WorkspaceSearchSheet` with injected results (no git). Same harness as
/// `RemotesRenderTests`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter WorkspaceSearchRenderTests
@MainActor
final class WorkspaceSearchRenderTests: RenderTestCase {
    private func sheet(mode: WorkspaceSearchSheet.Mode) -> some View {
        let ws = WorkspaceStore(configStore: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-search-render-\(UUID().uuidString).json")))
        let api = RepositoryStore(url: URL(fileURLWithPath: "/tmp/api-server"))
        let web = RepositoryStore(url: URL(fileURLWithPath: "/tmp/web-client"))
        let results: [WorkspaceSearchSheet.RepoResults] = mode == .workingTree
            ? [WorkspaceSearchSheet.RepoResults(repo: api, hits: [
                   GrepHit(path: "Sources/Auth/TokenStore.swift", line: 42, text: "    let needle = keychain.read(\"needle\")"),
                   GrepHit(path: "README.md", line: 7, text: "Set NEEDLE_URL=http://localhost:8080 before running."),
               ]),
               WorkspaceSearchSheet.RepoResults(repo: web, hits: [
                   GrepHit(path: "src/app/config.ts", line: 3, text: "export const needle = process.env.NEEDLE ?? \"\";"),
               ])]
            : [WorkspaceSearchSheet.RepoResults(repo: api, commits: [
                   CommitInfo(hash: "a1b2c3d4e5", shortHash: "a1b2c3d", author: "Agent", date: "2026-09-20", subject: "Add needle token refresh"),
                   CommitInfo(hash: "f0e9d8c7b6", shortHash: "f0e9d8c", author: "Agent", date: "2026-09-18", subject: "Remove legacy needle fallback"),
               ])]
        return WorkspaceSearchSheet(workspace: ws, query: "needle", mode: mode, results: results)
    }

    func testRender_01_workingTree() async throws {
        print("Rendered:", try await renderPNG(sheet(mode: .workingTree), name: "workspace-search-01-grep", size: CGSize(width: 640, height: 480)))
    }

    func testRender_02_commitsDark() async throws {
        print("Rendered:", try await renderPNG(sheet(mode: .commits), name: "workspace-search-02-commits-dark", size: CGSize(width: 640, height: 480), colorScheme: .dark))
    }
}
