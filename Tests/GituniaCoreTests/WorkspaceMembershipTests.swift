import XCTest
@testable import GituniaCore

final class WorkspaceMembershipTests: XCTestCase {
    let everything: (String) -> Bool = { _ in true }

    func testSingleReposFirstThenFolderReposWithoutDuplicatesOrExcluded() {
        let file = WorkspaceFile(
            repositories: ["/p/solo", "/f/a"],
            folders: [.init(path: "/f", excluded: ["b"])]
        )
        let result = WorkspaceMembership.resolve(file, scans: ["/f": ["/f/a", "/f/b", "/f/c"]], exists: everything)
        XCTAssertEqual(result.present, [
            .init(path: "/p/solo", source: .single),
            .init(path: "/f/a", source: .single),
            .init(path: "/f/c", source: .folder("/f")),
        ])
        XCTAssertEqual(result.missing, [])
    }

    func testMissingSingleRepoAndMissingFolder() {
        let file = WorkspaceFile(repositories: ["/gone"], folders: [.init(path: "/nofolder")])
        let result = WorkspaceMembership.resolve(file, scans: [:], exists: { $0 != "/gone" })
        XCTAssertEqual(result.present, [])
        XCTAssertEqual(result.missing, ["/gone"])
        XCTAssertEqual(result.missingFolders, ["/nofolder"])
    }

    func testNestedExcludedPathIsRelativeToFolder() {
        let file = WorkspaceFile(folders: [.init(path: "/f", excluded: ["group/x"])])
        let result = WorkspaceMembership.resolve(file, scans: ["/f": ["/f/group/x", "/f/group/y"]], exists: everything)
        XCTAssertEqual(result.present.map(\.path), ["/f/group/y"])
    }

    func testRemoveSingleAndUndo() {
        var file = WorkspaceFile(repositories: ["/a", "/b"])
        let removal = file.remove(.init(path: "/a", source: .single))
        XCTAssertEqual(removal, .single("/a", excludedIn: []))
        XCTAssertEqual(file.repositories, ["/b"])
        file.undo(removal)
        XCTAssertEqual(file.repositories, ["/b", "/a"])
    }

    func testRemoveFolderRepoExcludesAndUndoRestores() {
        var file = WorkspaceFile(folders: [.init(path: "/f")])
        let removal = file.remove(.init(path: "/f/x/y", source: .folder("/f")))
        XCTAssertEqual(removal, .excluded(folders: ["/f"], path: "/f/x/y"))
        XCTAssertEqual(file.folders[0].excluded, ["x/y"])
        file.undo(removal)
        XCTAssertEqual(file.folders[0].excluded, [])
    }

    func testAddRepositoryCoveredByFolderUnexcludesInsteadOfDuplicating() {
        var file = WorkspaceFile(folders: [.init(path: "/f", excluded: ["x"])])
        file.addRepository("/f/x")
        XCTAssertEqual(file.repositories, [])
        XCTAssertEqual(file.folders[0].excluded, [])
        file.addRepository("/other")
        file.addRepository("/other")
        XCTAssertEqual(file.repositories, ["/other"])
    }

    func testLinkFolderIsIdempotentAndUnlinkRemoves() {
        var file = WorkspaceFile()
        file.linkFolder("/f"); file.linkFolder("/f")
        XCTAssertEqual(file.folders.map(\.path), ["/f"])
        file.unlinkFolder("/f")
        XCTAssertEqual(file.folders, [])
    }

    func testSetTagsSortsAndEmptyRemovesKey() {
        var file = WorkspaceFile()
        file.setTags(["b", "a"], for: "/r")
        XCTAssertEqual(file.tags["/r"], ["a", "b"])
        file.setTags([], for: "/r")
        XCTAssertNil(file.tags["/r"])
    }

    func testRemoveSingleInsideLinkedFolderExcludesItAndUndoRestores() {
        var file = WorkspaceFile(repositories: ["/f/a"], folders: [.init(path: "/f")])
        let scans = ["/f": ["/f/a", "/f/b"]]
        let removal = file.remove(.init(path: "/f/a", source: .single))
        XCTAssertEqual(removal, .single("/f/a", excludedIn: ["/f"]))
        XCTAssertEqual(WorkspaceMembership.resolve(file, scans: scans, exists: everything).present.map(\.path), ["/f/b"])
        file.undo(removal)
        XCTAssertEqual(WorkspaceMembership.resolve(file, scans: scans, exists: everything).present.first,
                       .init(path: "/f/a", source: .single))
        XCTAssertEqual(file.folders[0].excluded, [])
    }

    func testAddRepositoryUnexcludesInEveryCoveringFolder() {
        var file = WorkspaceFile(folders: [.init(path: "/f"), .init(path: "/f/sub", excluded: ["x"])])
        file.addRepository("/f/sub/x")
        XCTAssertEqual(file.folders.flatMap(\.excluded), [])
        XCTAssertEqual(file.repositories, [])
    }

    func testRemoveFolderRepoExcludesItInEveryCoveringFolderAndUndoRestoresAll() {
        var file = WorkspaceFile(folders: [.init(path: "/c"), .init(path: "/c/a")])
        let scans = ["/c": ["/c/a/x"], "/c/a": ["/c/a/x"]]
        let entry = try! XCTUnwrap(WorkspaceMembership.resolve(file, scans: scans, exists: everything).present.first)
        let removal = file.remove(entry)
        XCTAssertEqual(WorkspaceMembership.resolve(file, scans: scans, exists: everything).present, [])
        file.undo(removal)
        XCTAssertEqual(WorkspaceMembership.resolve(file, scans: scans, exists: everything).present.map(\.path), ["/c/a/x"])
        XCTAssertEqual(file.folders.flatMap(\.excluded), [])
    }

    /// Migrated users can have a linked folder that is itself a repo.
    func testLinkedFolderThatIsItselfARepoUsesDotAsItsRelativePath() {
        XCTAssertEqual(WorkspaceMembership.relative("/a", in: "/a"), ".")
        XCTAssertEqual(WorkspaceMembership.absolute(".", in: "/a"), "/a")
        XCTAssertEqual(WorkspaceMembership.absolute("x/y", in: "/a"), "/a/x/y")
        var file = WorkspaceFile(folders: [.init(path: "/a")])
        let scans = ["/a": ["/a"]]
        let removal = file.remove(.init(path: "/a", source: .folder("/a")))
        XCTAssertEqual(file.folders[0].excluded, ["."])
        XCTAssertEqual(WorkspaceMembership.resolve(file, scans: scans, exists: everything).present, [])
        file.undo(removal)
        XCTAssertEqual(file.folders[0].excluded, [])
        _ = file.remove(.init(path: "/a", source: .folder("/a")))
        file.addRepository("/a")
        XCTAssertEqual(file.folders[0].excluded, [], "adding it back un-excludes it")
        XCTAssertEqual(file.repositories, [])
    }
}
