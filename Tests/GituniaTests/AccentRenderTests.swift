import XCTest
import SwiftUI
import AppKit
@testable import GituniaCore

/// Offscreen render of a prominent button and a brand dot, default vs. `accentOverride = .systemBlue`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter AccentRenderTests
@MainActor
final class AccentRenderTests: RenderTestCase {
    override func tearDown() {
        Theme.accentOverride = nil
        super.tearDown()
    }

    private func render(name: String) async throws -> String {
        let size = CGSize(width: 240, height: 80)
        let root = HStack(spacing: 20) {
            Button("Push") {}.buttonStyle(.borderedProminent).tint(Theme.brand)
            Circle().fill(Theme.brand).frame(width: 30, height: 30)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        return try await renderHostedPNG(root, name: name, size: size, appearance: .aqua, ticks: 10)
    }

    func testRender_defaultThenBlue() async throws {
        Theme.accentOverride = nil
        print("Rendered:", try await render(name: "accent-01-default"))
        Theme.accentOverride = .systemBlue
        print("Rendered:", try await render(name: "accent-02-blue"))
    }
}
