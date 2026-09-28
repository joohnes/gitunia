import XCTest
@testable import GituniaCore

@MainActor
final class HooksTests: XCTestCase {
    private func makeRepo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-hooks-\(UUID().uuidString)")
        return try await TestRepo.make(at: url, user: "T", email: "t@example.com")
    }

    private func writeHook(_ dir: URL, _ name: String, executable: Bool) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho hi\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path.path)
    }

    private func skipIfGlobalHooksPath() async throws {
        let global = try await GitRunner().run(["config", "--global", "--get", "core.hooksPath"], in: FileManager.default.temporaryDirectory, allowedExitCodes: [0, 1])
        try XCTSkipIf(!global.isEmpty, "global core.hooksPath set on this machine")
    }

    func testRepoHooks_flagsExecutableAndSample() async throws {
        try await skipIfGlobalHooksPath()
        let url = try await makeRepo()
        let hooksDir = url.appendingPathComponent(".git/hooks")
        try writeHook(hooksDir, "pre-commit", executable: true)
        try writeHook(hooksDir, "post-merge.sample", executable: true)
        let store = RepositoryStore(url: url)
        let hooks = await store.hooks()
        let pre = try XCTUnwrap(hooks.first { $0.name == "pre-commit" })
        XCTAssertTrue(pre.isExecutable); XCTAssertFalse(pre.isSample); XCTAssertTrue(pre.isActive)
        XCTAssertEqual(pre.firstLine, "#!/bin/sh")
        XCTAssertEqual(pre.source, .repo)
        let sample = try XCTUnwrap(hooks.first { $0.name == "post-merge.sample" })
        XCTAssertTrue(sample.isSample); XCTAssertFalse(sample.isActive)
        XCTAssertEqual(store.activeHookCount, 1)
        XCTAssertTrue(store.hasActiveHooks)
        let contents = await store.hookContents(pre)
        XCTAssertEqual(contents, "#!/bin/sh\necho hi\n")
    }

    func testRelativeHooksPath_resolvedAgainstRepoRoot() async throws {
        let url = try await makeRepo()
        _ = try await GitRunner().run(["config", "core.hooksPath", ".githooks"], in: url)
        try writeHook(url.appendingPathComponent(".githooks"), "pre-push", executable: true)
        let store = RepositoryStore(url: url)
        let hooks = await store.hooks()
        XCTAssertEqual(hooks.map(\.name), ["pre-push"])
        XCTAssertEqual(hooks.first?.source, .hooksPath(".githooks"))
        XCTAssertEqual(hooks.first?.path.resolvingSymlinksInPath(), url.appendingPathComponent(".githooks/pre-push").resolvingSymlinksInPath())
    }

    func testDisable_clearsExecutableBit() async throws {
        try await skipIfGlobalHooksPath()
        let url = try await makeRepo()
        try writeHook(url.appendingPathComponent(".git/hooks"), "pre-commit", executable: true)
        let store = RepositoryStore(url: url)
        let all = await store.hooks()
        let pre = try XCTUnwrap(all.first { $0.name == "pre-commit" })
        let error = await store.setHookEnabled(pre, false)
        XCTAssertNil(error)
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: pre.path.path))
        XCTAssertEqual(store.gitHooks.first { $0.name == "pre-commit" }?.isExecutable, false)
        XCTAssertFalse(store.hasActiveHooks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pre.path.path), "never deletes")
        _ = await store.setHookEnabled(pre, true)
        XCTAssertTrue(store.hasActiveHooks)
    }

    func testWorktree_usesCommonDirHooks() async throws {
        try await skipIfGlobalHooksPath()
        let url = try await makeRepo()
        try writeHook(url.appendingPathComponent(".git/hooks"), "pre-commit", executable: true)
        let wt = url.deletingLastPathComponent().appendingPathComponent("gitunia-hooks-wt-\(UUID().uuidString)")
        _ = try await GitRunner().run(["worktree", "add", "-q", "-b", "wt", wt.path], in: url)
        let store = RepositoryStore(url: wt)
        let all = await store.hooks()
        let pre = try XCTUnwrap(all.first { $0.name == "pre-commit" })
        XCTAssertEqual(pre.path.resolvingSymlinksInPath(), url.appendingPathComponent(".git/hooks/pre-commit").resolvingSymlinksInPath())
    }
}
