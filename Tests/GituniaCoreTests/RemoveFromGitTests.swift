import XCTest
@testable import GituniaCore

final class RemoveFromGitTests: XCTestCase {
    @MainActor
    func testStopTrackingKeepsFileAndIgnoresFolder() async throws {
        let url = try await TestRepo.make(files: ["build/out.o": "bin\n", "README.md": "hi\n"])
        let store = RepositoryStore(url: url)
        let error = await store.removeFromGit(["build/"], keepOnDisk: true, ignore: true)
        XCTAssertNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("build/out.o").path))
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(".gitignore"), encoding: .utf8), "/build/\n")
        XCTAssertEqual(store.stagedChanges.map(\.path), ["build/out.o"])
        XCTAssertEqual(store.stagedChanges.first?.status, .deleted)
    }

    @MainActor
    func testDeleteRefusesUncommittedEdits() async throws {
        let url = try await TestRepo.make(files: ["a.txt": "one\n"])
        try TestHelpers.write("edited\n", to: url, "a.txt")
        let store = RepositoryStore(url: url)
        let error = await store.removeFromGit(["a.txt"], keepOnDisk: false, ignore: false)
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("a.txt").path))
    }
}
