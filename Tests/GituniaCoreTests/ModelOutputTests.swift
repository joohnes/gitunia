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
