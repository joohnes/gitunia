import XCTest
import Observation
@testable import GituniaCore

/// The sidebar reads only `sidebarRows`/`sidebarChips`, and each row only its own store. With
/// agents committing continuously, a status refresh must invalidate only what actually changed —
/// never the whole list for a no-op tick. `withObservationTracking` over the same reads the views
/// make stands in for counting SwiftUI body evaluations.
@MainActor
final class SidebarInvalidationTests: XCTestCase {
    final class Flag: @unchecked Sendable { var fired = false }

    private func track(_ reads: @escaping () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking(reads) { flag.fired = true }
        return flag
    }

    private func sidebar(_ ws: WorkspaceStore) -> Flag { track { _ = ws.sidebarRows; _ = ws.sidebarChips } }
    private func row(_ store: RepositoryStore) -> Flag { track { _ = store.repo; _ = store.operation; _ = store.branches } }

    /// Lets the store's re-tracking task run.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }

    private func makeWorkspace() async throws -> (WorkspaceStore, a: RepositoryStore, b: RepositoryStore) {
        let root = try TestHelpers.makeTempDir()
        for name in ["a", "b", "c"] {
            try await TestRepo.make(at: root.appendingPathComponent(name), files: ["README.md": "hi\n"])
        }
        let ws = WorkspaceStore(configStore: ConfigStore(fileURL: root.appendingPathComponent("config.json")))
        await ws.openUntitled(linkingFolder: root)
        ws.stopWatching()
        try await settle()
        let a = try XCTUnwrap(ws.repositories.first { $0.repo.name == "a" })
        let b = try XCTUnwrap(ws.repositories.first { $0.repo.name == "b" })
        return (ws, a, b)
    }

    func testNoOpRefreshInvalidatesNothing() async throws {
        let (ws, a, b) = try await makeWorkspace()
        let list = sidebar(ws), rowA = row(a), rowB = row(b)
        await a.refreshStatus()
        try await settle()
        XCTAssertFalse(list.fired, "sidebar list re-rendered for a refresh that changed nothing")
        XCTAssertFalse(rowA.fired, "row re-rendered for a refresh that changed nothing")
        XCTAssertFalse(rowB.fired)
    }

    func testChangeThatKeepsOrderAndCountsTouchesOnlyItsRow() async throws {
        let (ws, a, _) = try await makeWorkspace()
        try "x".write(to: a.url.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        await a.refreshStatus()
        try await settle()
        XCTAssertEqual(ws.sidebarRows.map(\.repo.repo.name), ["a", "b", "c"], "changed first")

        let list = sidebar(ws), rowA = row(a)
        try "y".write(to: a.url.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        await a.refreshStatus()
        try await settle()
        XCTAssertTrue(rowA.fired)
        XCTAssertFalse(list.fired, "order and chip counts unchanged — the list must not re-render")
    }

    func testChangeThatMovesARowOrCountUpdatesTheList() async throws {
        let (ws, _, b) = try await makeWorkspace()
        let list = sidebar(ws)
        try "x".write(to: b.url.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        await b.refreshStatus()
        try await settle()
        XCTAssertTrue(list.fired)
        XCTAssertEqual(ws.sidebarRows.map(\.repo.repo.name), ["b", "a", "c"])
        XCTAssertEqual(ws.sidebarChips.first { $0.scope == .changed }?.count, 1)

        ws.scope = .changed
        try await settle()
        XCTAssertEqual(ws.sidebarRows.map(\.repo.repo.name), ["b"])
    }
}
