import XCTest
@testable import GituniaCore

/// Fake `gh` (no network): records argv one per line, copies the `--body-file` to `body`, prints a
/// canned URL or the canned `pr list` JSON.
final class GitHubPostTests: XCTestCase {
    private static let script = """
    #!/bin/sh
    D="$(dirname "$0")"
    for a in "$@"; do printf '%s\\n' "$a"; done > "$D/args"
    prev=""
    for a in "$@"; do [ "$prev" = "--body-file" ] && cp "$a" "$D/body"; prev="$a"; done
    case "$1 $2" in
      "pr comment") echo "https://github.com/acme/app/pull/12#issuecomment-99" ;;
      "issue create") echo "Creating issue in acme/app"; echo; echo "https://github.com/acme/app/issues/7" ;;
      "pr list") echo '[{"headRefName":"feat/x","number":12,"title":"Add the thing","url":"https://github.com/acme/app/pull/12"},{"headRefName":"fix/y","number":13,"title":"Fix","url":"https://github.com/acme/app/pull/13"}]' ;;
    esac
    """

    @MainActor
    private func makeStore(remote: String = "https://github.com/acme/app.git", ghPath: String? = nil) async throws -> (RepositoryStore, URL) {
        let url = try await TestHelpers.makeTempRepo()
        _ = try await GitRunner().run(["remote", "add", "origin", remote], in: url)
        let bin = try TestHelpers.makeTempDir()
        let path = bin.appendingPathComponent("gh").path
        try Self.script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let store = RepositoryStore(url: url)
        store.gh = GHRunner(executable: ghPath ?? path)
        return (store, bin)
    }

    private func args(_ bin: URL) throws -> [String] {
        try String(contentsOf: bin.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @MainActor
    func testPullRequestCommentPassesBodyFile() async throws {
        let (store, bin) = try await makeStore()
        let result = await store.postPullRequestComment(number: 12, body: "# Report\n- a")
        XCTAssertEqual(try result.get().absoluteString, "https://github.com/acme/app/pull/12#issuecomment-99")
        let a = try args(bin)
        XCTAssertEqual(Array(a.prefix(4)), ["pr", "comment", "12", "--body-file"])
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("body"), encoding: .utf8), "# Report\n- a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a[4]), "temp body file is cleaned up")
    }

    @MainActor
    func testCreateIssuePassesTitleAndLabels() async throws {
        let (store, bin) = try await makeStore()
        let result = await store.createIssue(title: "Agent activity", body: "body", labels: ["agent-activity", "report"])
        XCTAssertEqual(try result.get().absoluteString, "https://github.com/acme/app/issues/7")
        var a = try args(bin)
        a[5] = "<file>"
        XCTAssertEqual(a, ["issue", "create", "--title", "Agent activity", "--body-file", "<file>",
                           "--label", "agent-activity", "--label", "report"])
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("body"), encoding: .utf8), "body")
    }

    @MainActor
    func testOpenPullRequestsParsesList() async throws {
        let (store, bin) = try await makeStore()
        let prs = await store.openPullRequests()
        XCTAssertEqual(prs.map(\.number), [12, 13])
        XCTAssertEqual(prs.first?.headRefName, "feat/x")
        XCTAssertEqual(prs.first?.url, "https://github.com/acme/app/pull/12")
        XCTAssertEqual(try args(bin), ["pr", "list", "--state", "open", "--json", "number,title,headRefName,url", "--limit", "50"])
        let slug = await store.gitHubSlug()
        XCTAssertEqual(slug, "acme/app")
    }

    /// `isAvailable` checks the executable is actually there, not just non-nil, so a stale/bogus
    /// path (unlike `GHRunner(executable: nil)`, which falls back to the machine's real gh) now
    /// fakes "gh not installed" without spawning anything.
    @MainActor
    func testMissingGHExecutableFailsWithoutRunningIt() async throws {
        let (store, bin) = try await makeStore(ghPath: "/nonexistent/gh")
        XCTAssertFalse(store.gh.isAvailable)
        let result = await store.postPullRequestComment(number: 12, body: "x")
        XCTAssertEqual(result.failureError, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("args").path))
    }

    /// The sheet's enabling guard's other half — gh installed, but origin isn't GitHub.
    @MainActor
    func testNonGitHubOriginFailsWithoutRunningGH() async throws {
        let (store, bin) = try await makeStore(remote: "https://gitlab.com/acme/app.git")
        let supported = await store.supportsGitHubPost()
        XCTAssertFalse(supported)
        let result = await store.createIssue(title: "t", body: "b", labels: [])
        XCTAssertEqual(result.failureError, .failed("origin isn't a GitHub remote."))
        let prs = await store.openPullRequests()
        XCTAssertTrue(prs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("args").path))
    }
}

private extension Result {
    var failureError: Failure? { if case .failure(let e) = self { return e }; return nil }
}
