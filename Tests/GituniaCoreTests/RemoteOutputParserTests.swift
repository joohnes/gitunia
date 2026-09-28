import XCTest
@testable import GituniaCore

/// Drives real git commands and feeds their actual stdout/stderr into `RemoteOutputParser`,
/// rather than guessing at git's wording.
final class RemoteOutputParserTests: XCTestCase {
    private func makeRepoWithRemote() async throws -> (repo: URL, remote: URL) {
        let repo = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        let git = GitRunner()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", remote.path], in: repo)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        return (repo, remote)
    }

    func testFetchWithNewRefs() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        let git = GitRunner()
        _ = try await git.run(["push", "-u", "origin", "HEAD"], in: repo)
        let clone = try TestHelpers.makeTempDir().appendingPathComponent("clone")
        _ = try await git.run(["clone", "-q", remote.path, clone.path], in: repo)
        try TestHelpers.write("y\n", to: repo, "y.txt")
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "feat: y"], in: repo)
        _ = try await git.run(["push", "-q"], in: repo)

        let (out, err) = try await git.runCombined(["fetch", "--prune"], in: clone)
        XCTAssertTrue(err.hasPrefix("From "), "expected a 'From <remote>' header, got: \(err)")
        XCTAssertEqual(RemoteOutputParser.summary(for: .fetch, stdout: out, stderr: err), "Fetched 1 ref")
    }

    /// The `Fast-forward` block does not state the commit count directly, so the parser
    /// reports the diffstat footer instead — e.g. "Pulled — 3 files changed".
    func testPullFastForwardReportsDiffstat() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        let git = GitRunner()
        _ = try await git.run(["push", "-u", "origin", "HEAD"], in: repo)
        let clone = try TestHelpers.makeTempDir().appendingPathComponent("clone")
        _ = try await git.run(["clone", "-q", remote.path, clone.path], in: repo)

        for name in ["y.txt", "z.txt", "w.txt"] {
            try TestHelpers.write("\(name)\n", to: repo, name)
        }
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "feat: three files"], in: repo)
        _ = try await git.run(["push", "-q"], in: repo)

        let (out, err) = try await git.runCombined(["pull", "--ff-only"], in: clone)
        XCTAssertTrue(out.contains("Fast-forward"), "expected a Fast-forward block, got: \(out)")
        XCTAssertEqual(RemoteOutputParser.summary(for: .pull, stdout: out, stderr: err), "Pulled — 3 files changed")
    }

    // MARK: - Failure classification (real stderr, not guessed wording)

    /// `pull --ff-only` on a genuinely diverged branch prints a "Diverging branches" hint on stderr
    /// and fails with "fatal: Not possible to fast-forward, aborting." — captured here from two
    /// real clones that each commit locally, so `pullFailureKind` is checked against git's actual
    /// wording rather than a guess at it.
    func testPullFailureKindClassifiesDivergedFromRealStderr() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        let git = GitRunner()
        _ = try await git.run(["push", "-u", "origin", "HEAD"], in: repo)
        let clone = try TestHelpers.makeTempDir().appendingPathComponent("clone")
        _ = try await git.run(["clone", "-q", remote.path, clone.path], in: repo)

        try TestHelpers.write("a\n", to: repo, "a.txt")
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "a change"], in: repo)
        _ = try await git.run(["push", "-q"], in: repo)

        try TestHelpers.write("b\n", to: clone, "b.txt")
        _ = try await git.run(["add", "-A"], in: clone)
        _ = try await git.run(["commit", "-q", "-m", "b change"], in: clone)
        _ = try await git.run(["fetch", "-q"], in: clone)

        do {
            _ = try await git.run(["pull", "--ff-only"], in: clone)
            XCTFail("expected pull --ff-only to fail on a diverged branch")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("Not possible to fast-forward"), "got: \(error.stderr)")
            XCTAssertEqual(RemoteOutputParser.pullFailureKind(stderr: error.stderr), .diverged)
        }
    }

    func testPushFailureKindNoUpstreamAndNoRemote() {
        XCTAssertEqual(RemoteOutputParser.pushFailureKind(stderr: "fatal: The current branch feat has no upstream branch.\nTo push the current branch and set the remote as upstream, use\n\n    git push --set-upstream origin feat\n"), .noUpstream)
        XCTAssertEqual(RemoteOutputParser.pushFailureKind(stderr: "fatal: The upstream branch of your current branch does not match\nthe name of your current branch.  To push to the upstream branch\n"), .noUpstream)
        XCTAssertEqual(RemoteOutputParser.pushFailureKind(stderr: "fatal: No configured push destination.\nEither specify the URL from the command-line or configure a remote repository using\n"), .noRemote)
    }
}
