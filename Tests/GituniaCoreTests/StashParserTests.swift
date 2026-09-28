import XCTest
@testable import GituniaCore

final class StashParserTests: XCTestCase {
    func testEmpty() { XCTAssertEqual(StashParser.parse(""), []) }

    func testDefaultAndCustomMessageAgainstRealGitOutput() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let git = GitRunner()
        // Default message (no -m): "WIP on <branch>: <hash> <subject>".
        try TestHelpers.write("changed\n", to: url, "README.md")
        _ = try await git.run(["stash", "push", "-u"], in: url)
        // Explicit message: "On <branch>: <message>".
        try TestHelpers.write("changed again\n", to: url, "README.md")
        _ = try await git.run(["stash", "push", "-u", "-m", "my custom message"], in: url)

        let out = try await git.run(["stash", "list", "--format=%gd%x1f%s"], in: url)
        let entries = StashParser.parse(out)

        XCTAssertEqual(entries.count, 2)
        // Most recent stash is index 0.
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].branch, "master")
        XCTAssertEqual(entries[0].message, "my custom message")

        XCTAssertEqual(entries[1].index, 1)
        XCTAssertEqual(entries[1].branch, "master")
        XCTAssertTrue(entries[1].message.contains("init"), "default WIP message should carry the original commit subject: \(entries[1].message)")
    }

    func testUnrecognizedSubjectFallsBackToWholeMessage() {
        let entries = StashParser.parse("stash@{0}\u{1f}some unusual subject with no prefix")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].branch, "")
        XCTAssertEqual(entries[0].message, "some unusual subject with no prefix")
    }
}
