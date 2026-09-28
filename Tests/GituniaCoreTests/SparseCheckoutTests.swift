import XCTest
@testable import GituniaCore

@MainActor
final class SparseCheckoutTests: XCTestCase {
    private let git = GitRunner()

    /// README.md at the root, plus `a/x.txt` and `b/c/y.txt`.
    private func makeMonorepo() async throws -> URL {
        let url = try await TestHelpers.makeTempRepo()
        for dir in ["a", "b/c"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try TestHelpers.write("x\n", to: url, "a/x.txt")
        try TestHelpers.write("y\n", to: url, "b/c/y.txt")
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "dirs"], in: url)
        return url
    }

    private func exists(_ url: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func testSetListAndDisable() async throws {
        let url = try await makeMonorepo()
        let store = RepositoryStore(url: url)
        var state = await store.sparseState()
        XCTAssertEqual(state, .off)

        var err = await store.setSparse(["a"])
        XCTAssertNil(err)
        state = await store.sparseState()
        XCTAssertEqual(state, SparseState(enabled: true, cone: true, patterns: ["a"]))
        XCTAssertTrue(exists(url, "a/x.txt"))
        XCTAssertFalse(exists(url, "b"))
        XCTAssertTrue(exists(url, "README.md"))

        let root = await store.topLevelDirectories()
        let underB = await store.topLevelDirectories(at: "HEAD:b")
        let underC = await store.topLevelDirectories(at: "HEAD:b/c")
        XCTAssertEqual(root, ["a", "b"], "read from HEAD, not the disk")
        XCTAssertEqual(underB, ["c"])
        XCTAssertEqual(underC, [])

        err = await store.setSparse([])
        XCTAssertNil(err)
        state = await store.sparseState()
        XCTAssertEqual(state.patterns, [])
        XCTAssertFalse(exists(url, "a"))
        XCTAssertTrue(exists(url, "README.md"))

        err = await store.disableSparse()
        XCTAssertNil(err)
        state = await store.sparseState()
        XCTAssertEqual(state, .off)
        XCTAssertTrue(exists(url, "b/c/y.txt"))
    }

    func testConeDirectoriesFromPatterns() {
        XCTAssertEqual(SparseState.coneDirectories(fromPatterns: ["/a/", "b/c/", "d"]), ["a", "b/c", "d"])
        XCTAssertEqual(SparseState.coneDirectories(fromPatterns: ["/*", "!/*/", "/docs/"]), ["docs"], "root-files pair is implied")
        XCTAssertNil(SparseState.coneDirectories(fromPatterns: ["!/docs/"]))
        XCTAssertNil(SparseState.coneDirectories(fromPatterns: ["*.md"]))
    }

    func testPartialSparseClone() async throws {
        let source = try await makeMonorepo()
        let bare = try TestHelpers.makeTempDir().appendingPathComponent("mono.git")
        _ = try await git.run(["clone", "-q", "--bare", source.path, bare.path], in: source)
        _ = try await git.run(["config", "uploadpack.allowFilter", "true"], in: bare)

        let ws = try TestHelpers.makeTempDir()
        let workspace = WorkspaceStore(configStore: ConfigStore(fileURL: try TestHelpers.makeTempDir().appendingPathComponent("c.json")))
        await workspace.openUntitled(linkingFolder: ws)
        defer { workspace.stopWatching() }
        let dest = try await workspace.cloneRepository(from: "file://\(bare.path)", named: "mono", in: ws,
                                                       options: CloneOptions(partial: true, sparse: true))
        let clone = RepositoryStore(url: dest)
        let cloneState = await clone.sparseState()
        XCTAssertEqual(cloneState, SparseState(enabled: true, cone: true, patterns: []))
        XCTAssertTrue(exists(dest, "README.md"))
        XCTAssertFalse(exists(dest, "a"))

        // `--filter` + promisor remotes: git 2.25+ (the installed one is 2.50).
        let version = try await git.run(["--version"], in: dest)
        // "git version 2.50.1 (Apple Git-155)"
        let words = version.split(separator: " ")
        let parts = words.count > 2 ? words[2].split(separator: ".").compactMap { Int($0) } : []
        guard parts.count >= 2, (parts[0], parts[1]) >= (2, 25) else { throw XCTSkip("git too old for partial clone: \(version)") }
        let promisor = try await git.run(["config", "--get", "remote.origin.promisor"], in: dest)
        let filter = try await git.run(["config", "--get", "remote.origin.partialclonefilter"], in: dest)
        XCTAssertEqual(promisor.trimmingCharacters(in: .whitespacesAndNewlines), "true")
        XCTAssertEqual(filter.trimmingCharacters(in: .whitespacesAndNewlines), "blob:none")
    }
}
