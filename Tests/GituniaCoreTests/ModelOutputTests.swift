import XCTest
@testable import GituniaCore

final class ModelOutputTests: XCTestCase {
    func testPlainJSON() throws {
        let m = try ModelOutput.parseCommitMessage(#"{"title":"feat: x","body":"because"}"#)
        XCTAssertEqual(m, CommitMessage(title: "feat: x", body: "because"))
    }

    func testFencedJSONWithChatter() throws {
        let raw = """
        Sure! Here is the message:
        ```json
        {"title": "fix: y", "body": ""}
        ```
        """
        XCTAssertEqual(try ModelOutput.parseCommitMessage(raw), CommitMessage(title: "fix: y", body: ""))
    }

    func testMissingBodyDefaultsToEmpty() throws {
        XCTAssertEqual(try ModelOutput.parseCommitMessage(#"{"title":"chore: z"}"#), CommitMessage(title: "chore: z"))
    }

    func testGarbageThrowsBadResponse() {
        XCTAssertThrowsError(try ModelOutput.parseCommitMessage("no json here")) { err in
            guard case AIError.badResponse(let raw) = err else { return XCTFail("wrong error") }
            XCTAssertEqual(raw, "no json here")
        }
    }
}
