import XCTest
@testable import GituniaCore

final class AgentProfileTests: XCTestCase {
    func testSubstringIsCaseInsensitiveOverNameAndEmail() {
        let p = AgentProfile(patterns: ["BOT@"])
        XCTAssertTrue(p.matches(author: "Build", email: "bot@example.com"))
        XCTAssertFalse(p.matches(author: "Alice", email: "alice@example.com"))
        XCTAssertTrue(AgentProfile(patterns: ["alice <"]).matches(author: "ALICE", email: "a@x"))
    }

    func testRegexPattern() {
        let p = AgentProfile(patterns: ["/^agent-[0-9]+ </"])
        XCTAssertTrue(p.matches(author: "Agent-42", email: "x@y"))
        XCTAssertFalse(p.matches(author: "my agent-42", email: "x@y"))
        XCTAssertFalse(AgentProfile(patterns: ["/[/"]).matches(author: "[", email: ""), "invalid regex matches nothing")
    }

    func testBlankPatternsMatchNothing() {
        XCTAssertFalse(AgentProfile(patterns: ["", "  "]).matches(author: "Alice", email: "a@x"))
    }

    func testDefaults() {
        let p = AgentProfile()
        XCTAssertEqual(p.patterns, AgentProfile.defaultPatterns)
        XCTAssertTrue(p.matches(author: "Claude", email: "noreply@anthropic.com"))
        XCTAssertTrue(p.matches(author: "dependabot[bot]", email: "49699333+dependabot[bot]@users.noreply.github.com"))
        XCTAssertFalse(p.matches(author: "Test", email: "test@example.com"))
    }

    func testPrefsRoundTripAndTolerantDecoding() throws {
        var prefs = RepoPrefs()
        XCTAssertNil(prefs.agentPatterns)
        var decoded = try JSONDecoder().decode(RepoPrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertNil(decoded.agentPatterns)
        prefs.agentPatterns = ["bot@"]
        decoded = try JSONDecoder().decode(RepoPrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.agentPatterns, ["bot@"])

        var settings = AppSettings()
        settings.agentProfile.patterns = ["/x/"]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).agentProfile.patterns, ["/x/"])
        // D20: a malformed value must surface (it's the ConfigStore corrupt-file path that backs up
        // and warns), not silently reset to defaults — only a genuinely *missing* key defaults.
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"agentProfile": 42}"#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).agentProfile, AgentProfile())
    }

    // MARK: - gitAuthorArgs (B8, pure)

    func testGitAuthorArgsEscapesSubstringPatterns() {
        let args = AgentProfile(patterns: ["bot@"]).gitAuthorArgs
        XCTAssertEqual(args, ["--author=bot@", "--regexp-ignore-case"])
        // A substring with regex metacharacters must come out literal.
        let escaped = AgentProfile(patterns: ["a.b+c"]).gitAuthorArgs
        XCTAssertEqual(escaped.first, "--author=a\\.b\\+c")
    }

    func testGitAuthorArgsPassesRegexPatternsRaw() {
        let args = AgentProfile(patterns: ["/^agent-[0-9]+ </"]).gitAuthorArgs
        XCTAssertEqual(args, ["--author=^agent-[0-9]+ <", "--regexp-ignore-case"])
    }

    func testGitAuthorArgsOneAuthorFlagPerPattern() {
        let args = AgentProfile(patterns: ["bot@", "claude"]).gitAuthorArgs
        XCTAssertEqual(args, ["--author=bot@", "--author=claude", "--regexp-ignore-case"])
    }

    func testGitAuthorArgsEmptyWhenNoPatterns() {
        XCTAssertEqual(AgentProfile(patterns: []).gitAuthorArgs, [])
        XCTAssertEqual(AgentProfile(patterns: ["", "  "]).gitAuthorArgs, [])
    }

    @MainActor
    func testStoreResolvesOverrideElseGlobal() {
        let store = RepositoryStore(url: URL(fileURLWithPath: "/nonexistent"))
        store.globalAgentProfile = AgentProfile(patterns: ["g"])
        XCTAssertEqual(store.agentProfile.patterns, ["g"])
        var prefs = RepoPrefs(); prefs.agentPatterns = ["r"]
        store.applySharedPrefs(prefs)
        XCTAssertEqual(store.agentProfile.patterns, ["r"])
    }
}
