import XCTest
@testable import GituniaCore

final class ModelOutputTests: XCTestCase {
    func testFencedJSONWithChatter() throws {
        let raw = """
        Sure! Here is the message:
        ```json
        {"title": "fix: y", "body": ""}
        ```
        """
        XCTAssertEqual(try ModelOutput.parseCommitMessage(raw), CommitMessage(title: "fix: y", body: ""))
    }

    func testGarbageThrowsBadResponse() {
        XCTAssertThrowsError(try ModelOutput.parseCommitMessage("no json here")) { err in
            guard case AIError.badResponse(let raw) = err else { return XCTFail("wrong error") }
            XCTAssertEqual(raw, "no json here")
        }
    }
}

final class ClaudeCLIProviderParseTests: XCTestCase {
    /// `--json-schema` puts the validated object in `structured_output`; `result` may still be prose.
    func testPrefersStructuredOutputOverResultText() throws {
        let envelope = #"{"type":"result","result":"What would you like help with?","structured_output":{"title":" feat: x ","body":"why"}}"#
        XCTAssertEqual(try ClaudeCLIProvider.parse(Data(envelope.utf8)), CommitMessage(title: "feat: x", body: "why"))
    }
}

final class ClaudeCLIProviderFailureTests: XCTestCase {
    private func message(_ exitCode: Int32, stdout: String = "", stderr: String = "") -> String? {
        ClaudeCLIProvider.failure(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: stderr)?.errorDescription
    }

    func testSuccessIsNotAFailure() {
        XCTAssertNil(message(0, stdout: #"{"type":"result","is_error":false,"result":"{}"}"#))
    }

    /// The case that used to show a bare "claude exited with 1:": the reason is only on stdout.
    func testErrorReportedOnStdoutIsShown() {
        let out = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 Overloaded"}"#
        let text = message(1, stdout: out)
        XCTAssertEqual(text, "claude exited with 1:\nAPI Error: 529 Overloaded")
    }

    func testIsErrorWithExitZeroStillFails() {
        XCTAssertNotNil(message(0, stdout: #"{"type":"result","is_error":true,"result":"Prompt is too long"}"#))
    }

    func testLoginProblemSuggestsLogin() throws {
        let out = #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#
        let text = try XCTUnwrap(message(1, stdout: out))
        XCTAssertTrue(text.contains("not signed in"), text)
        XCTAssertTrue(text.contains("Invalid API key"), text)
    }

    func testOldCLISuggestsUpdate() throws {
        let text = try XCTUnwrap(message(1, stderr: "error: unknown option '--json-schema'\n"))
        XCTAssertTrue(text.contains("claude update"), text)
        XCTAssertTrue(text.contains("--json-schema"), text)
    }

    func testMissingNodeIsExplained() throws {
        let text = try XCTUnwrap(message(127, stderr: "env: node: No such file or directory"))
        XCTAssertTrue(text.contains("`node` was not"), text)
    }

    func testMissingClaude() throws {
        let text = try XCTUnwrap(message(127, stderr: "env: claude: No such file or directory"))
        XCTAssertTrue(text.contains("not found"), text)
    }

    func testSilentFailureSaysHowToSeeTheError() throws {
        let text = try XCTUnwrap(message(1))
        XCTAssertTrue(text.contains("claude -p hello"), text)
    }
}
