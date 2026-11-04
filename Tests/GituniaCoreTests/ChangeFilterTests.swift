import XCTest
@testable import GituniaCore

final class ChangeFilterTests: XCTestCase {
    private let source = FileChange(path: "Sources/App/Main.swift", status: .modified, area: .unstaged)
    private let staged = FileChange(path: "Sources/App/Model.swift", status: .modified, area: .staged)
    private let untracked = FileChange(path: "Tests/NewTests.swift", status: .untracked, area: .unstaged)
    private let conflicted = FileChange(path: "package-lock.json", status: .conflicted, area: .unstaged)
    private let lockfile = FileChange(path: "web/package-lock.json", status: .modified, area: .unstaged)

    func testKinds() {
        XCTAssertEqual(ChangeFilter.kind(of: source), .unstaged)
        XCTAssertEqual(ChangeFilter.kind(of: staged), .staged)
        XCTAssertEqual(ChangeFilter.kind(of: untracked), .untracked)
        XCTAssertEqual(ChangeFilter.kind(of: conflicted), .conflicted)
    }

    func testDefaultHidesOnlyNoise() {
        let result = ChangeFilter().apply([source, staged, untracked, conflicted, lockfile])
        XCTAssertEqual(result.shown, [source, staged, untracked, conflicted])
        XCTAssertEqual(result.hidden, 1)
    }

    func testShowNoise() {
        let filter = ChangeFilter(hideNoise: false)
        XCTAssertTrue(filter.matches(lockfile))
    }

    func testKindToggle() {
        let filter = ChangeFilter(kinds: [.staged])
        XCTAssertEqual(filter.apply([source, staged, untracked]).shown, [staged])
    }

    func testQueryTermsAndExclusions() {
        XCTAssertTrue(ChangeFilter.matches(query: "app .swift", path: "Sources/App/Main.swift"))
        XCTAssertFalse(ChangeFilter.matches(query: "app .ts", path: "Sources/App/Main.swift"))
        XCTAssertFalse(ChangeFilter.matches(query: ".swift !tests", path: "Tests/NewTests.swift"))
        XCTAssertTrue(ChangeFilter.matches(query: ".swift !tests", path: "Sources/App/Main.swift"))
        XCTAssertTrue(ChangeFilter.matches(query: "  ", path: "anything"))
        XCTAssertTrue(ChangeFilter.matches(query: "!", path: "anything"))
    }

    func testRenameMatchesOldPath() {
        let rename = FileChange(path: "Sources/New.swift", oldPath: "Sources/Old.swift", status: .renamed, area: .staged)
        XCTAssertTrue(ChangeFilter(query: "old").matches(rename))
    }

    func testNoiseRules() {
        for path in ["Cargo.lock", "a/b/yarn.lock", "dist/app.min.js", "app.js.map", "__snapshots__/x.snap",
                     "node_modules/x/index.js", "api/user.pb.go", "Foo.xcodeproj/project.xcworkspace/xcuserdata/me.xcuserstate", ".DS_Store"] {
            XCTAssertTrue(ChangeFilter.isNoise(path), path)
        }
        for path in ["Sources/App/Main.swift", "README.md", "src/map.ts", "lockscreen.swift", "src/snapshot.ts"] {
            XCTAssertFalse(ChangeFilter.isNoise(path), path)
        }
    }
}
