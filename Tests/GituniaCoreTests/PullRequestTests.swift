import XCTest
@testable import GituniaCore

/// `gh` is never run for real: a fake script in a temp dir stands in for it (no network).
final class PullRequestTests: XCTestCase {
    static let sampleJSON = """
    {"baseRefName":"master","headRefName":"feat/x","isDraft":false,"number":42,"reviewDecision":"REVIEW_REQUIRED",\
    "state":"OPEN","title":"Add the thing","url":"https://github.com/acme/app/pull/42","statusCheckRollup":[\
    {"__typename":"CheckRun","completedAt":"2026-09-01T10:00:00Z","conclusion":"SUCCESS","detailsUrl":"https://x","name":"build","startedAt":"2026-09-01T09:58:00Z","status":"COMPLETED","workflowName":"CI"},\
    {"__typename":"CheckRun","conclusion":"FAILURE","name":"lint","status":"COMPLETED","workflowName":"CI"},\
    {"__typename":"StatusContext","context":"ci/circleci","startedAt":"2026-09-01T09:58:00Z","state":"SUCCESS","targetUrl":"https://y"},\
    {"__typename":"CheckRun","conclusion":"","name":"deploy","status":"IN_PROGRESS","workflowName":"CD"}]}
    """

    /// Fake gh: `pr view` prints `view.json` (or gh's "no pull requests found", or an auth failure
    /// when `fail` exists); `pr create` records its args and makes `created.json` the viewed PR.
    private static let script = """
    #!/bin/sh
    D="$(dirname "$0")"
    echo "$@" >> "$D/calls"
    case "$1 $2" in
      "pr view")
        [ -f "$D/fail" ] && { echo "HTTP 401: authentication required" >&2; exit 4; }
        [ -f "$D/view.json" ] && { cat "$D/view.json"; exit 0; }
        echo 'no pull requests found for branch "feat/x"' >&2; exit 1 ;;
      "pr create")
        for a in "$@"; do printf '%s\\n' "$a"; done > "$D/create-args"
        cp "$D/created.json" "$D/view.json"
        echo "https://github.com/acme/app/pull/43" ;;
    esac
    """

    private func makeScript(_ text: String, in dir: URL) throws -> String {
        let path = dir.appendingPathComponent("gh").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @MainActor
    private func makeStore(remote: String = "https://github.com/acme/app.git", script: String = script,
                           timeout: Double = 20) async throws -> (RepositoryStore, URL) {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feat/x"], in: url)
        _ = try await git.run(["remote", "add", "origin", remote], in: url)
        let bin = try TestHelpers.makeTempDir()
        let store = RepositoryStore(url: url)
        store.gh = GHRunner(executable: try makeScript(script, in: bin), timeout: timeout)
        await store.refreshStatus()
        return (store, bin)
    }

    func testDecodesMixedCheckRunAndStatusContext() throws {
        let pr = try JSONDecoder().decode(PullRequest.self, from: Data(Self.sampleJSON.utf8))
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.headRefName, "feat/x")
        XCTAssertEqual(pr.reviewDecision, "REVIEW_REQUIRED")
        let checks = try XCTUnwrap(pr.statusCheckRollup)
        XCTAssertEqual(checks.map(\.displayName), ["build", "lint", "ci/circleci", "deploy"])
        XCTAssertEqual(checks.map(\.outcome), [.passing, .failing, .passing, .pending])
        XCTAssertEqual(checks.map(\.result), ["SUCCESS", "FAILURE", "SUCCESS", "IN_PROGRESS"])
        XCTAssertEqual(pr.checksOutcome, .failing)
    }

    @MainActor
    func testViewThroughFakeGH() async throws {
        let (store, bin) = try await makeStore()
        try Self.sampleJSON.write(to: bin.appendingPathComponent("view.json"), atomically: true, encoding: .utf8)
        let pr = await store.refreshPullRequest()
        XCTAssertEqual(pr?.number, 42)
        XCTAssertEqual(store.currentPullRequest?.number, 42)
        XCTAssertTrue(store.pullRequestsSupported)
        XCTAssertNil(store.lastGHError)
        let calls = try String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertTrue(calls.hasPrefix("pr view --json number,title,state,url,isDraft,headRefName,baseRefName,reviewDecision,statusCheckRollup"))
    }

    @MainActor
    func testNoPullRequestFoundIsNilWithoutError() async throws {
        let (store, _) = try await makeStore()
        let pr = await store.refreshPullRequest()
        XCTAssertNil(pr)
        XCTAssertNil(store.lastGHError)
    }

    @MainActor
    func testOtherFailureSetsLastGHError() async throws {
        let (store, bin) = try await makeStore()
        FileManager.default.createFile(atPath: bin.appendingPathComponent("fail").path, contents: nil)
        let pr = await store.refreshPullRequest()
        XCTAssertNil(pr)
        XCTAssertEqual(store.lastGHError, "HTTP 401: authentication required")
    }

    @MainActor
    func testNonGitHubRemoteNeverCallsGH() async throws {
        let (store, bin) = try await makeStore(remote: "https://gitlab.com/acme/app.git")
        let pr = await store.refreshPullRequest()
        XCTAssertNil(pr)
        XCTAssertFalse(store.pullRequestsSupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("calls").path))
    }

    @MainActor
    func testCreatePassesArgsAndReadsBack() async throws {
        let (store, bin) = try await makeStore()
        let created = Self.sampleJSON.replacingOccurrences(of: "\"number\":42", with: "\"number\":43")
        try created.write(to: bin.appendingPathComponent("created.json"), atomically: true, encoding: .utf8)
        let result = await store.createPullRequest(title: "Add the thing", body: "- a\n- b", draft: true, base: "master")
        XCTAssertEqual(try result.get().number, 43)
        let args = try String(contentsOf: bin.appendingPathComponent("create-args"), encoding: .utf8)
        XCTAssertEqual(args.split(separator: "\n", omittingEmptySubsequences: false).dropLast(),
                       ["pr", "create", "--title", "Add the thing", "--body", "- a", "- b", "--draft", "--base", "master", "--head", "feat/x"])
    }

    @MainActor
    func testTimeoutReturnsNilQuickly() async throws {
        let (store, _) = try await makeStore(script: "#!/bin/sh\nexec sleep 30\n", timeout: 1)
        let start = Date()
        let pr = await store.refreshPullRequest()
        XCTAssertNil(pr)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(store.lastGHError, GHError.timeout.errorDescription)
    }
}
