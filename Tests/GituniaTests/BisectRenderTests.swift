import XCTest
import SwiftUI
import AppKit
@testable import Gitunia
@testable import GituniaCore

/// Offscreen renders of History with `BisectPanel` over a real bisect (testing / first bad found)
/// and the Start Bisect sheet. Same harness as `RemotesRenderTests`.
///
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter BisectRenderTests
@MainActor
final class BisectRenderTests: RenderTestCase {
    /// Six commits; `f.txt` contains "BUG" from c4 on. Bisect started with bad=HEAD good=c1.
    private func makeBisecting() async throws -> (RepositoryStore, [String]) {
        let url = try TestRepo.fixedRoot("bisect")
        let git = GitRunner()
        try await TestRepo.make(at: url, commit: false, user: "T", email: "t@example.com")
        let subjects = ["Add parser", "Handle empty input", "Refactor tokenizer", "Speed up lexer", "Add docs", "Bump version"]
        var hashes: [String] = []
        for (i, subject) in subjects.enumerated() {
            try (i >= 3 ? "BUG \(i)\n" : "ok \(i)\n").write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: url)
            let date = TestRepo.fixedDate.addingTimeInterval(TimeInterval(i) * 3600)
            _ = try await TestRepo.commit(at: url, args: ["-q", "-m", subject], date: date, user: "T", email: "t@example.com")
            hashes.append(try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let error = await store.bisectStart(bad: "HEAD", good: hashes[0])
        XCTAssertNil(error)
        return (store, hashes)
    }

    private func history(_ store: RepositoryStore) -> some View {
        HistoryView(repo: store, selection: .constant(nil), initialBranch: "master").environment(ToastCenter())
    }

    func testRender_01_testing() async throws {
        let (store, hashes) = try await makeBisecting()
        _ = await store.bisectMark(.good) // c3 is good → next test sits above it
        XCTAssertNotNil(store.bisect?.current)
        XCTAssertNil(store.bisect?.firstBad)
        XCTAssertEqual(store.bisect?.verdict(for: hashes[0]), .good)
        print("Rendered:", try await renderPNG(history(store), name: "bisect-01-testing", size: CGSize(width: 520, height: 420)))
    }

    func testRender_02_firstBad() async throws {
        let (store, hashes) = try await makeBisecting()
        var steps = 0
        while store.bisect?.firstBad == nil, steps < 10 {
            let content = try String(contentsOf: store.url.appendingPathComponent("f.txt"), encoding: .utf8)
            _ = await store.bisectMark(content.contains("BUG") ? .bad : .good)
            steps += 1
        }
        XCTAssertEqual(store.bisect?.firstBad, hashes[3])
        print("Rendered:", try await renderPNG(history(store), name: "bisect-02-first-bad", size: CGSize(width: 520, height: 420), colorScheme: .dark))
    }

    func testRender_03_startSheet() async throws {
        let (store, hashes) = try await makeBisecting()
        _ = await store.bisectReset()
        let sheet = BisectStartSheet(repo: store, good: String(hashes[0].prefix(7))).environment(ToastCenter())
        print("Rendered:", try await renderPNG(sheet, name: "bisect-03-start-sheet", size: CGSize(width: 420, height: 230)))
    }
}
