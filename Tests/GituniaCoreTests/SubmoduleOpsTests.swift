import XCTest
@testable import GituniaCore

@MainActor
final class SubmoduleOpsTests: XCTestCase {
    private let git = GitRunner()

    private func commitAll(_ url: URL, _ message: String) async throws {
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["-c", "user.email=t@e", "-c", "user.name=T", "-c", "commit.gpgsign=false", "commit", "-q", "-m", message], in: url)
    }

    private func makeRepo(_ url: URL, file: String) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await git.run(["init", "-q", "-b", "master"], in: url)
        try "1\n".write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await commitAll(url, "init \(file)")
    }

    func testParsers() {
        let modules = SubmoduleParser.parseGitmodules("""
        submodule.libs/a.b.path=libs/a
        submodule.libs/a.b.url=git@host:o/a.git
        submodule.libs/a.b.branch=master
        submodule.c.path=c
        submodule.c.url=../c
        """)
        XCTAssertEqual(modules["libs/a"]?.url, "git@host:o/a.git")
        XCTAssertEqual(modules["libs/a"]?.branch, "master")
        XCTAssertEqual(modules["c"]?.url, "../c")
        XCTAssertNil(modules["c"]?.branch)
        XCTAssertEqual(SubmoduleParser.parseRecorded("160000 abc 0\tlibs/a\u{0}100644 def 0\tREADME\u{0}"), ["libs/a": "abc"])
    }

    func testAddUpdateToRemoteSyncRemove() async throws {
        let base = try TestHelpers.makeTempDir()
        let lib = base.appendingPathComponent("lib"), app = base.appendingPathComponent("app")
        try await makeRepo(lib, file: "lib.txt")
        try "2\n".write(to: lib.appendingPathComponent("lib.txt"), atomically: true, encoding: .utf8)
        try await commitAll(lib, "second")
        try await makeRepo(app, file: "app.txt")
        let store = RepositoryStore(url: app)

        let addError = await store.addSubmodule(url: "file://\(lib.path)", path: "lib", branch: "master")
        XCTAssertNil(addError, addError?.stderr ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent(".gitmodules").path))
        let added = try XCTUnwrap(store.submodules.first)
        XCTAssertEqual(added.state, .current)
        XCTAssertEqual(added.url, "file://\(lib.path)")
        XCTAssertEqual(added.branch, "master")
        XCTAssertEqual(added.recordedCommit, added.checkedOutCommit)
        try await commitAll(app, "add lib")

        try "3\n".write(to: lib.appendingPathComponent("lib.txt"), atomically: true, encoding: .utf8)
        try await commitAll(lib, "third")
        let remoteError = await store.submoduleUpdateToRemote("lib", configOverrides: ["protocol.file.allow=always"])
        XCTAssertNil(remoteError, remoteError?.stderr ?? "")
        let moved = try XCTUnwrap(store.submodules.first)
        XCTAssertEqual(moved.state, .outOfDate)
        XCTAssertEqual(moved.recordedCommit, added.recordedCommit)
        XCTAssertNotEqual(moved.checkedOutCommit, added.checkedOutCommit)
        let info = await store.commitInfoForSubmodule("lib", hash: try XCTUnwrap(moved.checkedOutCommit))
        XCTAssertEqual(info?.subject, "third")

        let syncError = await store.syncSubmodules()
        XCTAssertNil(syncError)

        let removeError = await store.removeSubmodule("lib")
        XCTAssertNil(removeError, removeError?.stderr ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("lib").path))
        let gitmodules = (try? String(contentsOf: app.appendingPathComponent(".gitmodules"), encoding: .utf8)) ?? ""
        XCTAssertFalse(gitmodules.contains("lib"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent(".git/modules/lib").path))
        XCTAssertTrue(store.submodules.isEmpty)
    }

    /// B10: `submodule add --name libname` at path `vendor/lib` — the name (not the path) is what
    /// `removeSubmodule` must delete under `.git/modules/`.
    func testRemoveSubmoduleUsesGitmodulesName() async throws {
        let base = try TestHelpers.makeTempDir()
        let lib = base.appendingPathComponent("lib"), app = base.appendingPathComponent("app")
        try await makeRepo(lib, file: "lib.txt")
        try await makeRepo(app, file: "app.txt")
        let store = RepositoryStore(url: app)

        _ = try await git.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "libname",
                               "--", "file://\(lib.path)", "vendor/lib"], in: app)
        try await commitAll(app, "add lib")
        await store.refreshSubmodules()
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent(".git/modules/libname").path))

        let removeError = await store.removeSubmodule("vendor/lib")
        XCTAssertNil(removeError, removeError?.stderr ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent(".git/modules/libname").path))
    }

    /// B10: nested submodules (app → lib → core) aren't recorded in app's own index/`.gitmodules`,
    /// so `initSubmodule`/`submoduleUpdateToRemote` route to the parent submodule's checkout instead
    /// of failing.
    func testInitNestedSubmoduleRunsFromParentCheckout() async throws {
        let base = try TestHelpers.makeTempDir()
        let core = base.appendingPathComponent("core"), lib = base.appendingPathComponent("lib"), app = base.appendingPathComponent("app")
        try await makeRepo(core, file: "core.txt")
        try await makeRepo(lib, file: "lib.txt")
        _ = try await git.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", "file://\(core.path)", "core"], in: lib)
        try await commitAll(lib, "add core")
        try await makeRepo(app, file: "app.txt")
        let store = RepositoryStore(url: app)

        let addError = await store.addSubmodule(url: "file://\(lib.path)", path: "lib", branch: nil)
        XCTAssertNil(addError, addError?.stderr ?? "")
        try await commitAll(app, "add lib")

        let initLibError = await store.initSubmodule("lib", configOverrides: ["protocol.file.allow=always"])
        XCTAssertNil(initLibError, initLibError?.stderr ?? "")
        await store.refreshSubmodules()
        let nested = try XCTUnwrap(store.submodules.first { $0.path == "lib/core" })
        XCTAssertNil(nested.recordedCommit, "nested rows aren't in app's own index")

        let initCoreError = await store.initSubmodule("lib/core", configOverrides: ["protocol.file.allow=always"])
        XCTAssertNil(initCoreError, initCoreError?.stderr ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("lib/core/core.txt").path))
    }
}
