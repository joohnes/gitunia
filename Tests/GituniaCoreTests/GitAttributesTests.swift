import XCTest
@testable import GituniaCore

final class GitAttributesTests: XCTestCase {
    func testParseAttributesAndComments() {
        let rules = GitAttributes.parse("""
        # comment
        *.psd filter=lfs diff=lfs merge=lfs -text

        *.sh\teol=lf !diff text
        """)
        XCTAssertEqual(rules, [
            AttributeRule(pattern: "*.psd", attributes: ["filter": "lfs", "diff": "lfs", "merge": "lfs", "text": "false"]),
            AttributeRule(pattern: "*.sh", attributes: ["eol": "lf", "diff": "!", "text": "true"]),
        ])
    }

    func testPatterns() {
        XCTAssertTrue(GitAttributes.matches("*.psd", path: "art/deep/cover.psd"))   // basename at any depth
        XCTAssertFalse(GitAttributes.matches("*.psd", path: "cover.psd.txt"))
        XCTAssertTrue(GitAttributes.matches("assets/**/*.bin", path: "assets/a.bin"))
        XCTAssertTrue(GitAttributes.matches("assets/**/*.bin", path: "assets/x/y/a.bin"))
        XCTAssertFalse(GitAttributes.matches("assets/**/*.bin", path: "other/assets/a.bin"))
        XCTAssertTrue(GitAttributes.matches("/root.bin", path: "root.bin"))
        XCTAssertFalse(GitAttributes.matches("/root.bin", path: "sub/root.bin"))
        XCTAssertTrue(GitAttributes.matches("data?.csv", path: "x/data1.csv"))
        XCTAssertTrue(GitAttributes.matches("vendor/**", path: "vendor/a/b.c"))
    }

    func testIsLFSTrackedLastFilterRuleWins() {
        let rules = GitAttributes.parse("*.bin filter=lfs\nkeep/*.bin -filter\n*.md text")
        XCTAssertTrue(GitAttributes.isLFSTracked("a/b.bin", rules: rules))
        XCTAssertFalse(GitAttributes.isLFSTracked("keep/b.bin", rules: rules))
        XCTAssertFalse(GitAttributes.isLFSTracked("README.md", rules: rules))
    }
}
