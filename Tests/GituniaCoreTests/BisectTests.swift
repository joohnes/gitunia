import XCTest
@testable import GituniaCore

final class BisectTests: XCTestCase {
    func testParseRealShapedLogAndOutputs() {
        let log = """
        # bad: [074ce3b452828293d0c55b96bbb8b9d14aa75932] c6
        # good: [bea0b518158bdb3bfcc9d91b4120b1d7c5f3338f] c1
        git bisect start 'HEAD' 'HEAD~5'
        # good: [10b766aa290334117cc77168cdeabac043239e2c] c3
        git bisect good 10b766aa290334117cc77168cdeabac043239e2c
        # skip: [d02a524fbc51882803ead6e6440a588daad2cb8e] c5
        git bisect skip d02a524fbc51882803ead6e6440a588daad2cb8e
        # bad: [c5e2acf569b69c8198442b050f10046140445f2e] c4
        git bisect bad c5e2acf569b69c8198442b050f10046140445f2e

        """
        let testing = BisectLog.parse(log: log, lastOutput: """
        Bisecting: 2 revisions left to test after this (roughly 1 step)
        [10b766aa290334117cc77168cdeabac043239e2c] c3
        """)
        XCTAssertTrue(testing.isActive)
        XCTAssertEqual(testing.good, ["bea0b518158bdb3bfcc9d91b4120b1d7c5f3338f", "10b766aa290334117cc77168cdeabac043239e2c"])
        XCTAssertEqual(testing.bad, ["074ce3b452828293d0c55b96bbb8b9d14aa75932", "c5e2acf569b69c8198442b050f10046140445f2e"])
        XCTAssertEqual(testing.skipped, ["d02a524fbc51882803ead6e6440a588daad2cb8e"])
        XCTAssertEqual(testing.current, "10b766aa290334117cc77168cdeabac043239e2c")
        XCTAssertEqual(testing.remainingSteps, 1)
        XCTAssertNil(testing.firstBad)
        XCTAssertEqual(testing.verdict(for: "d02a524fbc51882803ead6e6440a588daad2cb8e"), .skip)

        let found = BisectLog.parse(log: log, lastOutput: """
        c5e2acf569b69c8198442b050f10046140445f2e is the first bad commit
        commit c5e2acf569b69c8198442b050f10046140445f2e
        Author: a <a@b>

            c4
        """)
        XCTAssertEqual(found.firstBad, "c5e2acf569b69c8198442b050f10046140445f2e")
        XCTAssertNil(found.current)
        XCTAssertNil(found.remainingSteps)

        let fromLogOnly = BisectLog.parse(log: log + "# first bad commit: [c5e2acf569b69c8198442b050f10046140445f2e] c4\n")
        XCTAssertEqual(fromLogOnly.firstBad, "c5e2acf569b69c8198442b050f10046140445f2e")
        XCTAssertFalse(BisectLog.parse(log: "").isActive)
    }

    /// Six commits c1…c6 on top of the temp repo's init commit; c4 onward contain "BUG".
    @MainActor
    private func makeSixCommitRepo() async throws -> (url: URL, store: RepositoryStore, hashes: [String]) {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        var hashes: [String] = []
        for i in 1...6 {
            try TestHelpers.write(i >= 4 ? "BUG \(i)\n" : "ok \(i)\n", to: url, "f.txt")
            _ = try await git.run(["add", "."], in: url)
            _ = try await git.run(["commit", "-q", "-m", "c\(i)"], in: url)
            hashes.append(try await git.run(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        return (url, store, hashes)
    }

    @MainActor
    func testBisectFindsFirstBadCommit() async throws {
        let (url, store, hashes) = try await makeSixCommitRepo()
        XCTAssertNil(store.operation)

        let startError = await store.bisectStart(bad: "HEAD", good: hashes[0])
        XCTAssertNil(startError)
        XCTAssertEqual(store.operation, .bisect)
        XCTAssertNotNil(store.bisect?.remainingSteps)

        var steps = 0
        while store.bisect?.firstBad == nil, steps < 10 {
            let current = try XCTUnwrap(store.bisect?.current)
            XCTAssertEqual(current, store.repo.headOID)
            let content = try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8)
            let markError = await store.bisectMark(content.contains("BUG") ? .bad : .good)
            XCTAssertNil(markError)
            steps += 1
        }
        XCTAssertEqual(store.bisect?.firstBad, hashes[3])
        XCTAssertEqual(store.operation, .bisect)
        XCTAssertEqual(store.bisect?.verdict(for: hashes[0]), .good)

        let resetError = await store.bisectReset()
        XCTAssertNil(resetError)
        XCTAssertNil(store.operation)
        XCTAssertNil(store.bisect)
        XCTAssertEqual(store.repo.headOID, hashes[5])
    }

    /// B7(c): the context menu offers "Bisect: Mark Good/Bad" on any commit, not just the one under
    /// test — `bisectMark(_:hash:)` must accept an explicit, non-current hash and still advance.
    @MainActor
    func testMarkingNonTestedCommitAdvancesBisect() async throws {
        let (_, store, hashes) = try await makeSixCommitRepo()
        let startError = await store.bisectStart(bad: "HEAD", good: hashes[0])
        XCTAssertNil(startError)
        let firstTested = try XCTUnwrap(store.bisect?.current)

        // Mark a commit that is neither the one under test nor already-known-good (hashes[0] was
        // the `good` boundary passed to `bisectStart` itself, which would be a no-op to re-mark).
        let markError = await store.bisectMark(.good, hash: hashes[1])
        XCTAssertNil(markError)
        XCTAssertEqual(store.bisect?.verdict(for: hashes[1]), .good)
        // Bisect moved on to test something new, rather than sitting stuck on `firstTested`.
        XCTAssertNotEqual(store.bisect?.current, firstTested)
        XCTAssertNotNil(store.bisect?.current)
    }

    @MainActor
    func testStartRefusedOnDirtyTree() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("dirty\n", to: url, "README.md")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let error = await store.bisectStart(bad: "HEAD", good: "HEAD")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.stderr.contains("uncommitted") ?? false)
        XCTAssertNil(store.operation)
    }
}
