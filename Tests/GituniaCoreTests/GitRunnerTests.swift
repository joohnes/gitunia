import XCTest
@testable import GituniaCore

final class GitRunnerTests: XCTestCase {
    func testFailureThrowsGitErrorWithStderr() async {
        do {
            _ = try await GitRunner().run(["nonsense-command"], in: URL(fileURLWithPath: "/tmp"))
            XCTFail("expected throw")
        } catch let e as GitError {
            XCTAssertNotEqual(e.exitCode, 0)
            XCTAssertTrue(e.stderr.contains("nonsense-command"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testStdinIsPassed() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("x\n", to: repo, "x.txt")
        _ = try await GitRunner().run(["add", "x.txt"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-F", "-"], in: repo, stdin: "feat: from stdin\n\nbody here")
        let log = try await GitRunner().run(["log", "-1", "--pretty=%s%n%b"], in: repo)
        XCTAssertTrue(log.hasPrefix("feat: from stdin\nbody here"))
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let big = String(repeating: "line of text that is long enough\n", count: 20_000) // ~660 KB
        try TestHelpers.write(big, to: repo, "big.txt")
        let out = try await GitRunner().run(
            ["diff", "--no-index", "/dev/null", "big.txt"],
            in: repo,
            allowedExitCodes: [0, 1]
        ).count
        XCTAssertGreaterThan(out, 600_000)
    }

    func testLargeStdinWithLargeOutputDoesNotDeadlock() async throws {
        let input = String(repeating: "line of text that is long enough\n", count: 30_000) // ~1 MB
        let result = try await ProcessRunner.run(executable: "/bin/cat", arguments: [], stdin: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, input.count)
    }

    // MARK: - C1: repo-local config can't run commands behind the app's back

    /// A `.git/config` whose `core.fsmonitor` runs an arbitrary command is a known attack: plain
    /// `git status` would execute it with no user action. `GitRunner` forces `-c
    /// core.fsmonitor=false` on every call, so the marker file that command would create must never
    /// appear.
    func testFsmonitorCommandInRepoConfigNeverRuns() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let marker = repo.appendingPathComponent("pwned").path
        _ = try await GitRunner().run(
            ["config", "core.fsmonitor", "!touch \(marker)"], in: repo
        )
        _ = try? await GitRunner().run(["status", "--porcelain=v2"], in: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    // MARK: - C2/L9: literal pathspecs

    /// Without `literalPathspecs`, git's own glob pathspec matching would make `a[1].txt` also
    /// match `a1.txt`. `literalPathspecs: true` (`GIT_LITERAL_PATHSPECS=1`) must confine the
    /// operation to exactly the named file.
    func testLiteralPathspecsConfineGlobLikeNameToItself() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("one", to: repo, "a1.txt")
        try TestHelpers.write("bracket", to: repo, "a[1].txt")
        _ = try await GitRunner().run(["add", "-A", "--", "a[1].txt"], in: repo, literalPathspecs: true)
        let staged = try await GitRunner().run(["diff", "--cached", "--name-only"], in: repo)
        XCTAssertEqual(staged.trimmingCharacters(in: .whitespacesAndNewlines), "a[1].txt")
    }

    /// Documents the reason `literalPathspecs` is opt-in rather than always-on (see `GitRunner`):
    /// verified against real git that a pathspec-*less* `stash push -u` silently leaves the
    /// untracked file behind when `GIT_LITERAL_PATHSPECS=1` is set unconditionally. The default
    /// (`literalPathspecs: false`) must not regress this.
    func testPathspecLessStashPushStillRemovesUntrackedFileByDefault() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("untracked", to: repo, "u.txt")
        _ = try await GitRunner().runCombined(["stash", "push", "-u", "-m", "t"], in: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("u.txt").path))
    }

    func testRunDataReturnsRawBytes() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        let bytes = Data([0x00, 0xFF, 0x89, 0x50, 0x4E, 0x47, 0x0A, 0x00])
        try bytes.write(to: repo.appendingPathComponent("blob.bin"))
        _ = try await GitRunner().run(["add", "blob.bin"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "bin"], in: repo)
        let out = try await GitRunner().runData(["show", "HEAD:blob.bin"], in: repo)
        XCTAssertEqual(out, bytes)
    }
}
