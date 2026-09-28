import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen renders for tags / branch-from-commit / merged cleanup — same technique as
/// `FileHistoryRenderTests` (real offscreen `NSWindow`, needed for `List`s).
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter TagsRenderTests
@MainActor
final class TagsRenderTests: RenderTestCase {
    private func render(_ view: some View, size: CGSize, name: String) async throws {
        print("Rendered: \(try await renderHostedPNG(view, name: name, size: size))")
    }

    /// Repo with three commits: `v1.0` (lightweight) on the first, `v2.0` (annotated) and
    /// `release/latest` on HEAD; a merged `done-a`/`done-b` and an unmerged `wip`.
    private func makeRepo() async throws -> RepositoryStore {
        let url = try TestRepo.fixedRoot("tags")
        let git = GitRunner()
        func write(_ text: String, _ name: String) throws {
            try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
        _ = try await git.run(["tag", "v1.0"], in: url)
        for (i, subject) in ["feat: add parser", "fix: handle empty input"].enumerated() {
            try write("\(i)\n", "f\(i).txt")
            _ = try await git.run(["add", "."], in: url)
            _ = try await TestRepo.commit(at: url, args: ["-q", "-m", subject], date: TestRepo.fixedDate.addingTimeInterval(TimeInterval(i + 1) * 3600))
        }
        _ = try await git.run(["branch", "done-a"], in: url)
        _ = try await git.run(["branch", "done-b"], in: url)
        _ = try await git.run(["checkout", "-q", "-b", "wip"], in: url)
        try write("w\n", "w.txt")
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "wip"], date: TestRepo.fixedDate.addingTimeInterval(10_800))
        _ = try await git.run(["checkout", "-q", "master"], in: url)
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        _ = await store.createTag("v2.0", at: "HEAD", message: "Second release\n\nParser + fixes")
        _ = await store.createTag("release/latest", at: "HEAD")
        return store
    }

    /// tags-01: History rows with tag capsules — two on HEAD, one on the root commit.
    func testRender_historyTagBadges() async throws {
        let store = try await makeRepo()
        var selection: CommitInfo?
        let view = HistoryView(repo: store, selection: Binding(get: { selection }, set: { selection = $0 }))
            .environment(ToastCenter())
        try await render(view, size: CGSize(width: 340, height: 300), name: "tags-01-history-badges")
    }

    /// tags-02: the Tags sheet content with the repo's real tags.
    func testRender_tagsSheet() async throws {
        let store = try await makeRepo()
        let view = TagsSheetContent(tags: store.gitTags, remote: "origin", onCheckout: { _ in }, onPush: { _ in },
                                    onDelete: { _ in }, onDeleteRemote: { _ in }, onPushAll: {}, onDone: {})
        try await render(view, size: CGSize(width: 460, height: 330), name: "tags-02-tags-sheet")
    }

    /// tags-03: create-tag sheet with a message (→ annotated hint) and a real duplicate-name error.
    func testRender_createTagSheet() async throws {
        let store = try await makeRepo()
        let head = await store.history(limit: 1).first!
        let outcome = await store.createTag("v2.0", at: head.hash)
        XCTAssertEqual(outcome, .duplicateName)
        let view = CreateTagSheetContent(commit: head, name: .constant("v2.0"), message: .constant("Hotfix build"),
                                         error: "A tag named \"v2.0\" already exists", onCancel: {}, onCreate: {})
        try await render(view, size: CGSize(width: 400, height: 250), name: "tags-03-create-tag")
    }

    /// tags-04: merged cleanup — real candidates, one unchecked, plus git's real refusal for `wip`.
    func testRender_mergedBranchesSheet() async throws {
        let store = try await makeRepo()
        let candidates = await store.mergedBranchCandidates()
        let found = try XCTUnwrap(candidates)
        XCTAssertEqual(found.branches, ["done-a", "done-b"])
        let result = await store.deleteMergedBranches(["wip"])
        let view = MergedBranchesSheetContent(base: found.base, isLoading: false, candidates: found.branches,
                                              selected: .constant(["done-a"]), refused: result.refused,
                                              onCancel: {}, onDelete: {})
        try await render(view, size: CGSize(width: 420, height: 330), name: "tags-04-merged-branches")
    }
}
