import XCTest
@testable import GituniaCore

final class BranchParserTests: XCTestCase {
    func testLocalAndRemote() {
        let out = "refs/heads/main\t*\nrefs/heads/feat/x\t \nrefs/remotes/origin/HEAD\t \nrefs/remotes/origin/main\t \nrefs/remotes/origin/feat/y\t \n"
        XCTAssertEqual(BranchParser.parse(out), [
            BranchInfo(name: "main", isCurrent: true, isRemote: false),
            BranchInfo(name: "feat/x", isCurrent: false, isRemote: false),
            BranchInfo(name: "origin/main", isCurrent: false, isRemote: true),
            BranchInfo(name: "origin/feat/y", isCurrent: false, isRemote: true),
        ])
    }

    func testEmpty() { XCTAssertEqual(BranchParser.parse(""), []) }
}

final class BranchPinningTests: XCTestCase {
    func testDefaultBranchesArePinnedFirstAndRestKeepOrder() {
        let branches = [
            BranchInfo(name: "feature/b", isCurrent: false, isRemote: false),
            BranchInfo(name: "main", isCurrent: true, isRemote: false),
            BranchInfo(name: "a", isCurrent: false, isRemote: false),
            BranchInfo(name: "origin/master", isCurrent: false, isRemote: true),
        ]
        let split = branches.localPinnedFirst
        XCTAssertEqual(split.pinned.map(\.name), ["main"])
        XCTAssertEqual(split.rest.map(\.name), ["feature/b", "a"])
        XCTAssertTrue(BranchInfo(name: "origin/master", isCurrent: false, isRemote: true).isDefaultBranch)
        XCTAssertFalse(BranchInfo(name: "mainline", isCurrent: false, isRemote: false).isDefaultBranch)
    }
}
