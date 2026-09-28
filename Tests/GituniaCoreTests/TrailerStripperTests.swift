import XCTest
@testable import GituniaCore

final class TrailerStripperTests: XCTestCase {
    func testMixedCaseCoAuthoredByAtEndIsRemovedWithItsParagraph() {
        let body = "Explain the change.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nco-authored-by: Bot <b@x.io>\n"
        XCTAssertEqual(TrailerStripper.strip(text: body), "Explain the change.")
        XCTAssertEqual(TrailerStripper.findings(in: body).count, 2)
    }

    func testTrailerInMiddleOnlyThatLineGoes() {
        let body = "First.\nGenerated-by: some-agent\nSecond line stays."
        XCTAssertEqual(TrailerStripper.strip(text: body), "First.\nSecond line stays.")
    }

    func testRobotGeneratedWithLineRemoved() {
        let body = "Body.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\nAssisted-by: x"
        XCTAssertEqual(TrailerStripper.strip(text: body), "Body.")
    }

    func testSignedOffByHumanKeptBotRemoved() {
        let human = "Body.\n\nSigned-off-by: Jane Doe <jane@example.com>"
        XCTAssertEqual(TrailerStripper.strip(text: human), human)
        let bot = "Body.\n\nSigned-off-by: Jane Doe <jane@example.com>\nSigned-off-by: renovate[bot] <r@x.io>\nSigned-off-by: Claude <noreply@anthropic.com>"
        XCTAssertEqual(TrailerStripper.strip(text: bot), "Body.\n\nSigned-off-by: Jane Doe <jane@example.com>")
    }

    func testMiddleTrailerRemovalCollapsesDoubleBlank() {
        let body = "para1\n\nCo-Authored-By: X\n\npara2"
        XCTAssertEqual(TrailerStripper.strip(text: body), "para1\n\npara2")
    }

    func testIntentionalDoubleBlankWithNoTrailersStaysByteIdentical() {
        let body = "para1\n\n\npara2"
        XCTAssertEqual(TrailerStripper.strip(text: body), body)
    }

    func testNoTrailersIsByteIdentical() {
        let body = "Line one  \n\n  indented: not a trailer key\nRefs: #12\n\n\n"
        XCTAssertEqual(TrailerStripper.strip(text: body), body)
        let msg = CommitMessage(title: "fix: thing", body: body)
        XCTAssertEqual(TrailerStripper.strip(msg), msg)
    }

    func testTitleOnlyMessageUnchanged() {
        let msg = CommitMessage(title: "feat: add x")
        XCTAssertEqual(TrailerStripper.strip(msg), msg)
    }

    func testAppSettingsWithoutKeyDecodesToTrue() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiProvider":"ollama"}"#.utf8))
        XCTAssertTrue(settings.stripAgentTrailers)
    }
}
