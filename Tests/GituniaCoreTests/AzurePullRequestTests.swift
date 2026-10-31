import XCTest
@testable import GituniaCore

/// `az` is never run for real: a fake script stands in for it, and `gh` is made unavailable.
final class AzurePullRequestTests: XCTestCase {
    static let prJSON = """
    {"pullRequestId":7,"title":"Add the thing","status":"active","isDraft":true,\
    "sourceRefName":"refs/heads/feat/x","targetRefName":"refs/heads/main",\
    "repository":{"webUrl":"https://dev.azure.com/acme/proj/_git/app"},"createdBy":{"displayName":"x"}}
    """

    /// `repos pr list` prints `list.json` (else `[]`); `repos pr create` records its args and prints the PR.
    private static let script = """
    #!/bin/sh
    D="$(dirname "$0")"
    echo "$@" >> "$D/calls"
    case "$1 $2 $3" in
      "repos pr list") [ -f "$D/list.json" ] && cat "$D/list.json" || echo "[]" ;;
      "repos pr policy") [ -f "$D/policy.json" ] && cat "$D/policy.json" || exit 1 ;;
      "repos pr create")
        for a in "$@"; do printf '%s\\n' "$a"; done > "$D/create-args"
        cat "$D/pr.json" ;;
    esac
    """

    @MainActor
    private func makeStore(remote: String) async throws -> (RepositoryStore, URL) {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        _ = try await git.run(["checkout", "-q", "-b", "feat/x"], in: url)
        _ = try await git.run(["remote", "add", "origin", remote], in: url)
        let bin = try TestHelpers.makeTempDir()
        let path = bin.appendingPathComponent("az").path
        try Self.script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try Self.prJSON.write(to: bin.appendingPathComponent("pr.json"), atomically: true, encoding: .utf8)
        let store = RepositoryStore(url: url)
        store.gh = GHRunner(executable: "/nonexistent/gh")
        store.az = GHRunner(executable: path)
        await store.refreshStatus()
        return (store, bin)
    }

    @MainActor
    func testListMapsAzurePullRequest() async throws {
        let (store, bin) = try await makeStore(remote: "git@ssh.dev.azure.com:v3/acme/proj/app")
        try "[\(Self.prJSON)]".write(to: bin.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)
        let fetched = await store.refreshPullRequest()
        let pr = try XCTUnwrap(fetched)
        XCTAssertTrue(store.pullRequestsSupported)
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.state, "OPEN")
        XCTAssertTrue(pr.isDraft)
        XCTAssertEqual(pr.headRefName, "feat/x")
        XCTAssertEqual(pr.baseRefName, "main")
        XCTAssertEqual(pr.url, "https://dev.azure.com/acme/proj/_git/app/pullrequest/7")
        XCTAssertEqual(store.currentPullRequest?.number, 7)
    }

    func testReviewerVotesMapToReviewDecision() throws {
        func decision(_ reviewers: String) throws -> String? {
            let json = Self.prJSON.replacingOccurrences(of: "\"createdBy\"", with: "\"reviewers\":\(reviewers),\"createdBy\"")
            return try JSONDecoder().decode(AzurePullRequest.self, from: Data(json.utf8)).reviewDecision
        }
        XCTAssertNil(try decision("[]"))
        XCTAssertEqual(try decision(#"[{"vote":0}]"#), "REVIEW_REQUIRED")
        XCTAssertEqual(try decision(#"[{"vote":5},{"vote":0}]"#), "APPROVED")
        XCTAssertEqual(try decision(#"[{"vote":10,"isRequired":true},{"vote":0,"isRequired":true}]"#), "REVIEW_REQUIRED")
        XCTAssertEqual(try decision(#"[{"vote":10},{"vote":-5}]"#), "CHANGES_REQUESTED")
    }

    @MainActor
    func testPoliciesBecomeChecks() async throws {
        let (store, bin) = try await makeStore(remote: "git@ssh.dev.azure.com:v3/acme/proj/app")
        try "[\(Self.prJSON)]".write(to: bin.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)
        try """
        [{"status":"approved","configuration":{"type":{"displayName":"Minimum number of reviewers"},"settings":{}}},
         {"status":"rejected","configuration":{"type":{"displayName":"Build"},"settings":{"displayName":"CI"}}},
         {"status":"running","configuration":{"type":{"displayName":"Build"},"settings":{"displayName":""}}}]
        """.write(to: bin.appendingPathComponent("policy.json"), atomically: true, encoding: .utf8)
        let fetched = await store.refreshPullRequest()
        let checks = try XCTUnwrap(fetched?.statusCheckRollup)
        XCTAssertEqual(checks.map(\.displayName), ["Minimum number of reviewers", "CI", "Build"])
        XCTAssertEqual(checks.map(\.outcome), [.passing, .failing, .pending])
        XCTAssertEqual(fetched?.checksOutcome, .failing)
        let calls = try String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertTrue(calls.contains("repos pr policy list --id=7 --output json"))
    }

    @MainActor
    func testEmptyListIsNilWithoutError() async throws {
        let (store, _) = try await makeStore(remote: "https://acme.visualstudio.com/proj/_git/app")
        let pr = await store.refreshPullRequest()
        XCTAssertNil(pr)
        XCTAssertNil(store.lastGHError)
        XCTAssertTrue(store.pullRequestsSupported)
    }

    @MainActor
    func testCreateUsesEqualsFormSoDashValuesSurvive() async throws {
        let (store, bin) = try await makeStore(remote: "https://acme@dev.azure.com/acme/proj/_git/app")
        _ = await store.refreshPullRequest()
        let result = await store.createPullRequest(title: "-weird title", body: "- a\n- b", draft: true, base: "main")
        XCTAssertEqual(try result.get().number, 7)
        XCTAssertEqual(store.currentPullRequest?.number, 7)
        let args = try String(contentsOf: bin.appendingPathComponent("create-args"), encoding: .utf8)
        XCTAssertEqual(args.split(separator: "\n", omittingEmptySubsequences: false).dropLast(),
                       ["repos", "pr", "create", "--title=-weird title", "--source-branch=feat/x", "--output", "json",
                        "--description=- a", "- b", "--draft", "true", "--target-branch=main"])
    }

    @MainActor
    func testOtherHostNeverCallsAz() async throws {
        let (store, bin) = try await makeStore(remote: "https://gitlab.com/acme/app.git")
        let pr = await store.refreshPullRequest()
        XCTAssertNil(pr)
        XCTAssertFalse(store.pullRequestsSupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("calls").path))
    }
}
