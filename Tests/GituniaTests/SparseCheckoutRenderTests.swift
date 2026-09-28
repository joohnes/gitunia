import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

final class SparseCheckStateTests: XCTestCase {
    @MainActor
    func testConeCheckStates() {
        let sel: Set<String> = ["services/api"]
        XCTAssertEqual(SparseCheckoutSheet.checkState("services/api", selected: sel), .on)
        XCTAssertEqual(SparseCheckoutSheet.checkState("services/api/v2", selected: sel), .inherited)
        XCTAssertEqual(SparseCheckoutSheet.checkState("services", selected: sel), .partial)
        XCTAssertEqual(SparseCheckoutSheet.checkState("serv", selected: sel), .off)
        XCTAssertEqual(SparseCheckoutSheet.toggling("services", in: sel), ["services"], "parent swallows checked children")
        XCTAssertEqual(SparseCheckoutSheet.toggling("services/api", in: sel), [])
        XCTAssertEqual(SparseCheckoutSheet.statusLine(SparseState(enabled: true, cone: true, patterns: ["a", "b", "c"])),
                       "Sparse checkout on, cone mode, 3 folders")
        XCTAssertEqual(SparseCheckoutSheet.statusLine(.off), "Off — full checkout")
    }
}

/// Offscreen render of `SparseCheckoutSheet` with injected state and tree (same harness as
/// `RemotesRenderTests`).
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter SparseCheckoutRenderTests
@MainActor
final class SparseCheckoutRenderTests: RenderTestCase {
    private let tree: [String: [String]] = [
        "": ["apps", "docs", "libs", "services", "tools"],
        "services": ["api", "billing", "worker"],
        "services/api": ["v1", "v2"],
        "libs": ["ui", "core"],
    ]

    func testRender_01_coneTree() async throws {
        let store = RepositoryStore(url: try TestPaths.tempDir())
        let state = SparseState(enabled: true, cone: true, patterns: ["docs", "libs/core", "services/api"])
        let sheet = SparseCheckoutSheet(repo: store, state: state, tree: tree, expanded: ["services", "services/api", "libs"])
            .environment(ToastCenter())
        print("Rendered:", try await renderPNG(sheet, name: "sparse-01-cone-tree", size: CGSize(width: 520, height: 520)))
    }

    func testRender_02_nonCone() async throws {
        let store = RepositoryStore(url: try TestPaths.tempDir())
        let state = SparseState(enabled: true, cone: false, patterns: ["/*", "!/*/", "/docs/"])
        let sheet = SparseCheckoutSheet(repo: store, state: state, tree: tree).environment(ToastCenter())
        print("Rendered:", try await renderPNG(sheet, name: "sparse-02-non-cone", size: CGSize(width: 520, height: 520), colorScheme: .dark))
    }
}

private enum TestPaths {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-sparse-render-\(UUID().uuidString)/mono")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
