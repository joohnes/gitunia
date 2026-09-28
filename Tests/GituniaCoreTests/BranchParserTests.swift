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
}

final class DashRefTests: XCTestCase {
    /// `git update-ref refs/heads/--output=x` succeeds even though `git branch` refuses the name;
    /// passed on as a bare revision, `git log` would read it as `--output` and write a file.
    func testParserDropsRefsThatLookLikeOptions() {
        let out = "refs/heads/--output=/tmp/x\t \nrefs/heads/-n\t \nrefs/heads/ok\t*\nrefs/remotes/origin/-x\t \n"
        XCTAssertEqual(BranchParser.parse(out).map(\.name), ["ok", "origin/-x"])
    }

    @MainActor
    func testHistoryNeverTreatsBranchAsOption() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let target = url.appendingPathComponent("pwned.txt")
        let store = RepositoryStore(url: url)
        _ = await store.history(branch: "--output=\(target.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
