import XCTest
@testable import GituniaCore

final class ReviewPointTests: XCTestCase {
    @MainActor
    func testUnreviewedSinceReviewPoint_thenMarkReviewed_thenResetPastIt() async throws {
        let url = try await TestHelpers.makeTempRepo() // commit 1: "init"
        let store = RepositoryStore(url: url)
        try TestHelpers.write("2\n", to: url, "two.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "two"))
        await store.refreshStatus()
        XCTAssertNil(store.unreviewedCount, "never reviewed → no count")
        store.reviewedHead = store.repo.headOID // reviewed at commit 2

        try TestHelpers.write("3\n", to: url, "three.txt")
        await store.stageAll()
        _ = await store.commit(CommitMessage(title: "three"))
        await store.refreshStatus()

        XCTAssertEqual(store.unreviewedCount, 1)
        XCTAssertFalse(store.reviewPointMissing)

        var persisted: String?
        store.onMarkReviewed = { persisted = $0.reviewedHead }
        store.markReviewed()
        XCTAssertEqual(persisted, store.repo.headOID)
        XCTAssertEqual(store.unreviewedCount, 0)
        await store.refreshStatus()
        XCTAssertEqual(store.unreviewedCount, 0)

        _ = try await GitRunner().run(["reset", "-q", "--hard", "HEAD~1"], in: url)
        await store.refreshStatus()
        XCTAssertTrue(store.reviewPointMissing)
        XCTAssertNil(store.unreviewedCount)
        XCTAssertTrue(store.reviewPointMissing)
    }
}
