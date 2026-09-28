import XCTest
@testable import GituniaCore

@MainActor
final class BlobTests: XCTestCase {
    private func makeStore() async throws -> RepositoryStore {
        let repo = try await TestHelpers.makeTempRepo()
        return RepositoryStore(url: repo)
    }

    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])

    private func commitFile(_ store: RepositoryStore, path: String, data: Data) async throws {
        let fileURL = store.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        _ = try await GitRunner().run(["add", "--", path], in: store.url)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add \(path)"], in: store.url)
    }

    func testBlobContentMatchesCommittedBytes() async throws {
        let store = try await makeStore()
        try await commitFile(store, path: "shot.png", data: pngBytes)
        let content = await store.blobContent(path: "shot.png", at: "HEAD")
        XCTAssertEqual(content, pngBytes)
    }

    func testBlobContentHandlesSpaceInFilename() async throws {
        let store = try await makeStore()
        try await commitFile(store, path: "my photo.png", data: pngBytes)
        let content = await store.blobContent(path: "my photo.png", at: "HEAD")
        XCTAssertEqual(content, pngBytes)
    }

    func testBlobContentNilForMissingPath() async throws {
        let store = try await makeStore()
        let content = await store.blobContent(path: "nope.png", at: "HEAD")
        XCTAssertNil(content)
    }

    func testPreviewFileAtHEADHasRightExtensionAndContent() async throws {
        let store = try await makeStore()
        try await commitFile(store, path: "shot.png", data: pngBytes)
        let url = await store.previewFileForHEAD(path: "shot.png")
        let url2 = try XCTUnwrap(url)
        XCTAssertEqual(url2.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url2), pngBytes)
    }

    func testPreviewFileIsCachedAcrossCalls() async throws {
        let store = try await makeStore()
        try await commitFile(store, path: "shot.png", data: pngBytes)
        let firstResult = await store.previewFileForHEAD(path: "shot.png")
        let secondResult = await store.previewFileForHEAD(path: "shot.png")
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(first, second)
    }

    func testPreviewFileNilForMissingPath() async throws {
        let store = try await makeStore()
        let url = await store.previewFileForHEAD(path: "nope.png")
        XCTAssertNil(url)
    }

    func testPreviewFileWithNilRefReturnsWorkingTreePath() async throws {
        let store = try await makeStore()
        let fileURL = store.url.appendingPathComponent("README.md")
        let url = await store.previewFile(path: "README.md", at: nil)
        XCTAssertEqual(url?.standardizedFileURL, fileURL.standardizedFileURL)
    }

    func testPreviewFileWithNilRefReturnsNilWhenMissingFromDisk() async throws {
        let store = try await makeStore()
        let url = await store.previewFile(path: "gone.md", at: nil)
        XCTAssertNil(url)
    }
}
