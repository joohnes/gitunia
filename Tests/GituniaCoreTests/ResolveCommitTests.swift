import XCTest
@testable import GituniaCore

@MainActor
final class ResolveCommitTests: XCTestCase {
    func testResolvesHashesAndBranchesAndRejectsGarbage() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let head = try await GitRunner().run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)

        let full = await store.resolveCommit(head)
        let short = await store.resolveCommit(String(head.prefix(7)))
        let branch = await store.resolveCommit("master")
        let garbage = await store.resolveCommit("no-such-ref")
        let option = await store.resolveCommit("--all")
        XCTAssertEqual(full, head)
        XCTAssertEqual(short, head)
        XCTAssertEqual(branch, head)
        XCTAssertNil(garbage)
        XCTAssertNil(option)
    }
}
