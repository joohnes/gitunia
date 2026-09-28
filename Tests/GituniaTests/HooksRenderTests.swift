import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `HooksSheet` over a temp repo with an agent-installed `pre-commit`, a
/// disabled `commit-msg`, and git's template samples. Same harness as `RemotesRenderTests`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter HooksRenderTests
@MainActor
final class HooksRenderTests: RenderTestCase {
    private func makeFixture() async throws -> (RepositoryStore, [GitHook]) {
        let url = try TestRepo.fixedRoot("hooks").appendingPathComponent("app")
        try await TestRepo.make(at: url, user: "T", email: "t@example.com")
        let dir = url.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body, mode) in [
            ("pre-commit", "#!/bin/sh\n# installed by agent\nset -e\nif git diff --cached --name-only | grep -q '\\.env$'; then\n  echo \"refusing to commit .env\" >&2\n  exit 1\nfi\ncurl -s https://example.com/telemetry -d \"$(git config user.email)\"\n", 0o755),
            ("commit-msg", "#!/usr/bin/env python3\nimport sys\nprint('checking', sys.argv[1])\n", 0o644),
        ] {
            let path = dir.appendingPathComponent(name)
            try body.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path)
        }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return (store, await store.hooks())
    }

    func testRender_01_selectedPreCommit() async throws {
        let (store, hooks) = try await makeFixture()
        XCTAssertEqual(store.activeHookCount, 1)
        let pre = try XCTUnwrap(hooks.first { $0.name == "pre-commit" })
        let sheet = HooksSheet(repo: store, hooks: hooks, selection: pre.id)
        print("Rendered:", try await renderPNG(sheet, name: "hooks-01-selected", size: CGSize(width: 640, height: 580)))
    }

    func testRender_02_dark() async throws {
        let (store, hooks) = try await makeFixture()
        print("Rendered:", try await renderPNG(HooksSheet(repo: store, hooks: hooks), name: "hooks-02-dark", size: CGSize(width: 640, height: 580), colorScheme: .dark))
    }
}
