import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen render of `ApplyPatchSheet` with a pasted mailbox patch and an injected check result.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter ApplyPatchRenderTests
@MainActor
final class ApplyPatchRenderTests: RenderTestCase {
    private func makeStore() async throws -> RepositoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-patch-render-\(UUID().uuidString)/app")
        try await TestRepo.make(at: url, user: "T", email: "t@example.com")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return store
    }

    private let patch = """
    From 3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39 Mon Sep 17 00:00:00 2001
    From: Ada L <ada@example.com>
    Date: Tue, 22 Sep 2026 10:00:00 +0200
    Subject: [PATCH] Fix: shout two!

    ---
     a.txt | 2 +-
     1 file changed, 1 insertion(+), 1 deletion(-)

    diff --git a/a.txt b/a.txt
    --- a/a.txt
    +++ b/a.txt
    @@ -1,3 +1,3 @@
     one
    -two
    +TWO
     three
    """

    func testRender_01_mailboxApplies() async throws {
        let store = try await makeStore()
        let check = PatchCheck(applies: true, message: "Applies cleanly — 2 files: a.txt, Sources/App/Main.swift",
                               isMailbox: true, touchedFiles: ["a.txt", "Sources/App/Main.swift"])
        let sheet = ApplyPatchSheet(repo: store, initialText: patch, initialCheck: check).environment(ToastCenter())
        print("Rendered:", try await renderPNG(sheet, name: "apply-patch-01-mailbox", size: CGSize(width: 560, height: 520)))
    }

    func testRender_02_conflictDark() async throws {
        let store = try await makeStore()
        let check = PatchCheck(applies: false, message: "error: patch failed: a.txt:1\nerror: a.txt: patch does not apply",
                               isMailbox: false, touchedFiles: [])
        let sheet = ApplyPatchSheet(repo: store, initialText: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n", initialCheck: check)
            .environment(ToastCenter())
        print("Rendered:", try await renderPNG(sheet, name: "apply-patch-02-conflict-dark", size: CGSize(width: 560, height: 520), colorScheme: .dark))
    }
}
