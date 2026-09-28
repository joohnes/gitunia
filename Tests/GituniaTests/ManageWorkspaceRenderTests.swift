import XCTest
import SwiftUI
@testable import Gitunia
import GituniaCore

@MainActor
final class ManageWorkspaceRenderTests: RenderTestCase {
    private func makeRepo(_ name: String, in dir: URL) async throws -> URL {
        try await TestRepo.make(at: dir.appendingPathComponent(name), user: "T", email: "t@e")
    }

    func testRender_manageWorkspace() async throws {
        let base = try TestRepo.fixedRoot("manage")
        let agents = base.appendingPathComponent("agents")
        _ = try await makeRepo("api", in: agents)
        let old = try await makeRepo("old-experiment", in: agents)
        let solo = try await makeRepo("gitunia", in: base)
        let gone = try await makeRepo("gone", in: base)
        let cfg = base.appendingPathComponent("cfg/workspace.json")
        let store = WorkspaceStore(app: AppConfig(configStore: ConfigStore(fileURL: cfg)))
        await store.openUntitled()
        _ = try await store.addRepository(solo)
        _ = try await store.addRepository(gone)
        await store.addFolder(agents)
        await store.addFolder(base.appendingPathComponent("unplugged-disk"))
        _ = store.remove(try XCTUnwrap(store.repository(atPath: old.path)))
        try FileManager.default.removeItem(at: gone)
        await store.refreshAll()

        let view = ManageWorkspaceSheet(workspace: store)
            .environment(ToastCenter())
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 560, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); store.stopWatching() }
        for _ in 0..<15 { try? await Task.sleep(nanoseconds: 60_000_000); hosting.layoutSubtreeIfNeeded() }
        let path = try writePNG(hosting, name: "manage-workspace")
        print("Rendered: \(path)")
    }
}
