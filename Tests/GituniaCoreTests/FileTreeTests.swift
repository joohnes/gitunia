import XCTest
@testable import GituniaCore

final class FileTreeTests: XCTestCase {
    private func change(_ path: String, area: FileChange.Area = .unstaged) -> FileChange {
        FileChange(path: path, status: .modified, area: area)
    }

    private func build(_ changes: [FileChange], salt: String = "unstaged") -> [FileTreeNode<FileChange>] {
        FileTree.build(from: changes, path: \.path, salt: salt)
    }

    func testEmptyInput() {
        XCTAssertTrue(build([]).isEmpty)
    }

    func testFileAtRootHasNoDirectoryRow() {
        let tree = build([change("README.md")])
        XCTAssertEqual(tree.count, 1)
        guard case .file(let c, _, _) = tree[0] else { return XCTFail("expected file") }
        XCTAssertEqual(c.path, "README.md")
    }

    func testSingleChildChainCollapses() {
        // Sources/Gitunia/SidebarView.swift: Sources has only Gitunia as a child, Gitunia has only
        // the file — both levels should collapse into a single directory row.
        let tree = build([change("Sources/Gitunia/SidebarView.swift")])
        XCTAssertEqual(tree.count, 1)
        guard case .directory(let name, let path, _, let children) = tree[0] else { return XCTFail("expected directory") }
        XCTAssertEqual(name, "Sources/Gitunia")
        XCTAssertEqual(path, "Sources/Gitunia")
        XCTAssertEqual(children.count, 1)
        guard case .file(let c, _, _) = children[0] else { return XCTFail("expected file") }
        XCTAssertEqual(c.path, "Sources/Gitunia/SidebarView.swift")
    }

    func testDeepChainCollapsesFully() {
        let tree = build([
            change("x/y/z/f1.swift"),
            change("x/y/z/f2.swift"),
        ])
        XCTAssertEqual(tree.count, 1)
        guard case .directory(let name, let path, _, let children) = tree[0] else { return XCTFail("expected directory") }
        XCTAssertEqual(name, "x/y/z")
        XCTAssertEqual(path, "x/y/z")
        XCTAssertEqual(children.count, 2)
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

    func testFilesAtRootMixedWithNested() {
        let tree = build([
            change("README.md"),
            change("Sources/Gitunia/App.swift"),
        ])
        XCTAssertEqual(tree.count, 2)
        guard case .directory = tree[0] else { return XCTFail("expected directory first") }
        guard case .file(let c, _, _) = tree[1] else { return XCTFail("expected file second") }
        XCTAssertEqual(c.path, "README.md")
    }

    func testDirectoriesSortBeforeFilesCaseInsensitive() {
        let tree = build([
            change("zebra.swift"),
            change("Apple/thing.swift"),
            change("banana.swift"),
        ])
        XCTAssertEqual(tree.count, 3)
        guard case .directory(let name, _, _, _) = tree[0] else { return XCTFail("expected directory first") }
        XCTAssertEqual(name, "Apple")
        guard case .file(let f1, _, _) = tree[1] else { return XCTFail("expected file") }
        XCTAssertEqual(f1.path, "banana.swift")
        guard case .file(let f2, _, _) = tree[2] else { return XCTFail("expected file") }
        XCTAssertEqual(f2.path, "zebra.swift")
    }

    func testSharedPrefixButDifferentDirectoryDoesNotMerge() {
        let tree = build([
            change("src/foo.swift"),
            change("src2/bar.swift"),
        ])
        XCTAssertEqual(tree.count, 2)
        let names = tree.compactMap { node -> String? in
            if case .directory(let name, _, _, _) = node { return name }
            return nil
        }.sorted()
        XCTAssertEqual(names, ["src", "src2"])
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

    func testIdsStableAcrossEqualRebuilds() {
        let changes = [
            change("Sources/Gitunia/App.swift"),
            change("Sources/GituniaCore/Models.swift"),
            change("README.md"),
        ]
        let first = build(changes)
        let second = build(changes)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
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

    // MARK: - Generalised builder over a non-FileChange payload

    private struct HistoryFile: Equatable, Sendable {
        let path: String
    }

    func testWorksOverNonFileChangePayload() {
        let tree = FileTree.build(
            from: [HistoryFile(path: "Sources/Gitunia/App.swift"), HistoryFile(path: "README.md")],
            path: \.path, salt: "history"
        )
        XCTAssertEqual(tree.count, 2)
        guard case .directory(let name, _, _, let children) = tree[0] else { return XCTFail("expected directory first") }
        XCTAssertEqual(name, "Sources/Gitunia")
        guard case .file(let file, _, _) = children[0] else { return XCTFail("expected file") }
        XCTAssertEqual(file.path, "Sources/Gitunia/App.swift")
        guard case .file(let root, _, _) = tree[1] else { return XCTFail("expected file second") }
        XCTAssertEqual(root.path, "README.md")
    }

    /// Same path, same shape, but built for two different payload types with different salts —
    /// the ids must not collide, since a `FileChange` tree (Changes view) and a `FileDiff` tree
    /// (history view) never render in the same list but must still be safe to key independently.
    func testIdsNonCollidingAcrossDifferentUsesOfTheBuilder() {
        let changeTree = build([change("Sources/Gitunia/App.swift")], salt: "unstaged")
        let historyTree = FileTree.build(from: [HistoryFile(path: "Sources/Gitunia/App.swift")], path: \.path, salt: "history")
        XCTAssertNotEqual(changeTree[0].id, historyTree[0].id)
        guard case .directory(_, _, _, let changeChildren) = changeTree[0],
              case .directory(_, _, _, let historyChildren) = historyTree[0] else {
            return XCTFail("expected directories")
        }
        XCTAssertNotEqual(changeChildren[0].id, historyChildren[0].id)
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

    func testFlattenAllExpandedIncludesEveryRowInOrder() {
        let tree = build(nestedChanges())
        let rows = FileTree.flatten(tree, collapsed: [])
        // api/z.go, db/migration (dir), V185, V186, V187, internal/app (dir): directories sort
        // before files, so testdata (dir) comes before background.go/deps.go.
        let names: [String] = rows.map {
            switch $0.kind {
            case .directory(let name, _, _): return name
            case .file(_, let name): return name
            }
        }
        XCTAssertEqual(names, [
            "api", "z.go",
            "db/migration", "V185.sql", "V186.sql", "V187.sql",
            "internal/app", "testdata", "y.txt", "background.go", "deps.go",
        ])
    }

    func testFlattenDepthsReflectNesting() {
        let tree = build(nestedChanges())
        let rows = FileTree.flatten(tree, collapsed: [])
        func depth(_ name: String) -> Int? {
            rows.first {
                switch $0.kind {
                case .directory(let n, _, _): return n == name
                case .file(_, let n): return n == name
                }
            }?.depth
        }
        XCTAssertEqual(depth("api"), 0)
        XCTAssertEqual(depth("z.go"), 1)
        XCTAssertEqual(depth("db/migration"), 0)
        XCTAssertEqual(depth("V185.sql"), 1)
        XCTAssertEqual(depth("internal/app"), 0)
        XCTAssertEqual(depth("background.go"), 1)
        XCTAssertEqual(depth("testdata"), 1)
        XCTAssertEqual(depth("y.txt"), 2)
    }

    func testDirectoriesDefaultExpanded() {
        let tree = build(nestedChanges())
        let rows = FileTree.flatten(tree, collapsed: [])
        guard case .directory(_, _, let isExpanded) = rows.first(where: {
            if case .directory(let name, _, _) = $0.kind { return name == "db/migration" }
            return false
        })!.kind else { return XCTFail("expected directory row") }
        XCTAssertTrue(isExpanded)
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

    func testExpandingRestoresDescendantsInOrder() {
        let tree = build(nestedChanges())
        guard let internalAppID = tree.first(where: {
            if case .directory(let name, _, _, _) = $0 { return name == "internal/app" }
            return false
        }).map(\.id) else { return XCTFail("expected internal/app directory") }

        let collapsedRows = FileTree.flatten(tree, collapsed: [internalAppID])
        let expandedRows = FileTree.flatten(tree, collapsed: [])
        XCTAssertLessThan(collapsedRows.count, expandedRows.count)
        XCTAssertEqual(expandedRows, FileTree.flatten(tree, collapsed: []))
    }

    func testFlattenIdsStableAcrossTwoBuilds() {
        let changes = nestedChanges()
        let first = FileTree.flatten(build(changes), collapsed: [])
        let second = FileTree.flatten(build(changes), collapsed: [])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testCollapsedIdNoLongerInTreeIsHarmless() {
        let tree = build(nestedChanges())
        let rows = FileTree.flatten(tree, collapsed: ["dir:unstaged:no-longer-exists"])
        XCTAssertEqual(rows.count, FileTree.flatten(tree, collapsed: []).count)
    }

    func testEmptyTreeFlattensToEmptyRows() {
        XCTAssertTrue(FileTree.flatten([FileTreeNode<FileChange>](), collapsed: []).isEmpty)
    }
}
