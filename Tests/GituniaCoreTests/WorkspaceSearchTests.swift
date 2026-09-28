import XCTest
@testable import GituniaCore

final class WorkspaceSearchTests: XCTestCase {
    func testParseGrepKeepsColonsInTextAndPath() {
        let out = "src/a.swift\u{0}12\u{0}let url = \"http://x:80\"\nweird:name.txt\u{0}3\u{0}a: b\n"
        XCTAssertEqual(WorkspaceSearch.parseGrep(out), [
            GrepHit(path: "src/a.swift", line: 12, text: "let url = \"http://x:80\""),
            GrepHit(path: "weird:name.txt", line: 3, text: "a: b"),
        ])
    }

    func testParseGrepSkipsBinaryAndEmpty() {
        XCTAssertEqual(WorkspaceSearch.parseGrep("Binary file logo.png matches\nx.txt\u{0}1\u{0}hit\n"),
                       [GrepHit(path: "x.txt", line: 1, text: "hit")])
        XCTAssertEqual(WorkspaceSearch.parseGrep(""), [])
    }

    @MainActor
    func testGrepAndPickaxeAgainstRealRepos() async throws {
        let hitURL = try await TestHelpers.makeTempRepo()
        let missURL = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("one\ntwo needle three\n", to: hitURL, "notes.txt")
        let hit = RepositoryStore(url: hitURL), miss = RepositoryStore(url: missURL)

        let hits = await hit.grep("needle"), misses = await miss.grep("needle")
        XCTAssertEqual(hits, [GrepHit(path: "notes.txt", line: 2, text: "two needle three")])
        XCTAssertEqual(misses, [])

        let git = GitRunner()
        _ = try await git.run(["add", "-A"], in: hitURL)
        _ = try await git.run(["commit", "-q", "-m", "add the needle"], in: hitURL)
        let touching = await hit.commitsTouching("needle"), none = await miss.commitsTouching("needle")
        XCTAssertEqual(touching.map(\.subject), ["add the needle"])
        XCTAssertEqual(none, [])
    }
}
