import XCTest
@testable import GituniaCore

final class PushScanTests: XCTestCase {
    private static func commit(_ text: String, _ file: String, _ subject: String, in repo: URL) async throws -> String {
        let git = GitRunner()
        try TestHelpers.write(text, to: repo, file)
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "--no-verify", "-m", subject], in: repo)
        return try await git.run(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func testFindsSecretOnlyInUnpushedCommits() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        let store = RepositoryStore(url: repo)
        await store.refreshStatus()

        _ = try await Self.commit("clean\n", "a.txt", "chore: clean", in: repo)
        let firstPush = await store.push()
        XCTAssertTrue(firstPush.succeeded)
        let none = await store.unpushedSecretFindings()
        XCTAssertEqual(none, [])

        let hash = try await Self.commit("AWS=AKIAABCDEFGHIJKLMNOP\n", "keys.env", "feat: keys", in: repo)
        await store.refreshStatus()
        let found = await store.unpushedSecretFindings()
        XCTAssertEqual(found, [SecretScanner.Finding(path: "keys.env", label: "an AWS access key ID",
                                                     commitHash: hash, commitSubject: "feat: keys")])

        let secondPush = await store.push()
        XCTAssertTrue(secondPush.succeeded)
        let afterPush = await store.unpushedSecretFindings()
        XCTAssertEqual(afterPush, [])
    }

    @MainActor
    func testNoUpstreamScansAgainstAllRemotes() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        let store = RepositoryStore(url: repo)
        await store.refreshStatus()
        let pushed = await store.push()
        XCTAssertTrue(pushed.succeeded)

        // A new branch with no remote counterpart: only its own commit is unpushed.
        _ = try await git.run(["switch", "-q", "-c", "feature"], in: repo)
        let hash = try await Self.commit("token = abcdefghijklmnopqrstuvwxyz\n", "conf.ini", "feat: conf", in: repo)
        await store.refreshStatus()
        XCTAssertFalse(store.hasUpstream)
        let found = await store.unpushedSecretFindings()
        XCTAssertEqual(found.map(\.commitHash), [hash])
        XCTAssertEqual(found.map(\.path), ["conf.ini"])
    }

    /// C17: Push All's pre-flight scans repos in chunks of 8 rather than one after another.
    /// `flaggedForSecrets` isn't a pure function (each scan shells out to git), so this exercises it
    /// against real repos — some with an unpushed secret, some clean — across more than one chunk.
    @MainActor
    func testFlaggedForSecretsAcrossChunksFindsOnlyDirtyRepos() async throws {
        let ws = try TestHelpers.makeTempDir()
        var stores: [RepositoryStore] = []
        for i in 0..<10 {
            let repo = try await TestHelpers.makeTempRepo()
            let dest = ws.appendingPathComponent("r\(i)")
            try FileManager.default.moveItem(at: repo, to: dest)
            let git = GitRunner()
            let remote = try TestHelpers.makeTempDir().appendingPathComponent("r\(i)-remote.git")
            _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: dest)
            _ = try await git.run(["remote", "add", "origin", remote.path], in: dest)
            let store = RepositoryStore(url: dest)
            await store.refreshStatus()
            _ = await store.push()
            // Odd-indexed repos get an unpushed commit with a secret in it.
            if i % 2 == 1 {
                _ = try await Self.commit("AWS=AKIAABCDEFGHIJKLMNOP\n", "keys.env", "feat: keys", in: dest)
                await store.refreshStatus()
            }
            stores.append(store)
        }

        let flagged = await RepositoryStore.flaggedForSecrets(in: stores)
        XCTAssertEqual(Set(flagged.map { $0.repo.name }), Set(stores.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.repo.name }))
    }
}
