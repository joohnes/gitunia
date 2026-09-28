import XCTest
@testable import GituniaCore

final class FileTreeTests: XCTestCase {
    private func change(_ path: String, area: FileChange.Area = .unstaged) -> FileChange {
        FileChange(path: path, status: .modified, area: area)
    }

    private func build(_ changes: [FileChange], salt: String = "unstaged") -> [FileTreeNode<FileChange>] {
        FileTree.build(from: changes, path: \.path, salt: salt)
    }

    func testChainStopsWhenDirectoryHasTwoChildren() {
        let tree = build([
            change("a/b/one.swift"),
            change("a/b/c/two.swift"),
        ])
        XCTAssertEqual(tree.count, 1)
        // "a" has one child "b"; "b" has two children (one.swift, c/), so collapsing stops there.
        guard case .directory(let name, let path, _, let children) = tree[0] else { return XCTFail("expected directory") }
        XCTAssertEqual(name, "a/b")
        XCTAssertEqual(path, "a/b")
        XCTAssertEqual(children.count, 2)
        // directories sort before files: "c" before "one.swift"
        guard case .directory(let innerName, _, _, let innerChildren) = children[0] else { return XCTFail("expected directory first") }
        XCTAssertEqual(innerName, "c")
        XCTAssertEqual(innerChildren.count, 1)
        guard case .file = children[1] else { return XCTFail("expected file second") }
    }

    func testSamePathDifferentSaltsProduceDistinctIds() {
        let staged = build([change("Sources/Gitunia/App.swift", area: .staged)], salt: "staged")
        let unstaged = build([change("Sources/Gitunia/App.swift", area: .unstaged)], salt: "unstaged")
        XCTAssertNotEqual(staged[0].id, unstaged[0].id)
        guard case .directory(_, _, _, let stagedChildren) = staged[0], case .directory(_, _, _, let unstagedChildren) = unstaged[0] else {
            return XCTFail("expected directories")
        }
        XCTAssertNotEqual(stagedChildren[0].id, unstagedChildren[0].id)
    }

    /// A path that is both a file and a directory prefix — git reports this whenever a file is
    /// replaced by a directory of the same name. The subtree under it must not be swallowed.
    func testFileAndDirectoryWithSameNameBothAppear() {
        let nodes = build([change("config"), change("config/app.json")])
        XCTAssertEqual(nodes.count, 2)
        guard case .directory(let name, _, _, let children) = nodes[0] else { return XCTFail("expected directory first") }
        XCTAssertEqual(name, "config")
        XCTAssertEqual(children.count, 1)
        guard case .file(let nested, _, _) = children[0] else { return XCTFail("expected nested file") }
        XCTAssertEqual(nested.path, "config/app.json")
        guard case .file(let top, _, _) = nodes[1] else { return XCTFail("expected file second") }
        XCTAssertEqual(top.path, "config")
    }

    // MARK: - flatten

    /// Nested fixture matching the task's scenario: two directories each with several files, one
    /// directory nested inside another.
    private func nestedChanges() -> [FileChange] {
        [
            change("api/z.go"),
            change("db/migration/V185.sql"),
            change("db/migration/V186.sql"),
            change("db/migration/V187.sql"),
            change("internal/app/deps.go"),
            change("internal/app/testdata/y.txt"),
            change("internal/app/background.go"),
        ]
    }

    func testCollapsingDirectoryHidesAllDescendantsIncludingNested() {
        let tree = build(nestedChanges())
        guard let internalAppID = tree.first(where: {
            if case .directory(let name, _, _, _) = $0 { return name == "internal/app" }
            return false
        }).map(\.id) else { return XCTFail("expected internal/app directory") }

        let rows = FileTree.flatten(tree, collapsed: [internalAppID])
        let names: [String] = rows.map {
            switch $0.kind {
            case .directory(let name, _, _): return name
            case .file(_, let name): return name
            }
        }
        // internal/app's own row stays, but background.go, deps.go, testdata, and testdata/y.txt
        // (a nested directory's contents) are all gone.
        XCTAssertEqual(names, [
            "api", "z.go",
            "db/migration", "V185.sql", "V186.sql", "V187.sql",
            "internal/app",
        ])
        guard case .directory(_, _, let isExpanded) = rows.last!.kind else { return XCTFail("expected directory") }
        XCTAssertFalse(isExpanded)
    }
}
