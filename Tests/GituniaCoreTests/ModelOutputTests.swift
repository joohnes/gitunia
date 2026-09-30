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
