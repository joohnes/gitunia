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
}
