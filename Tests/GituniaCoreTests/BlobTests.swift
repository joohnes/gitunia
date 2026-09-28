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
        for path in ["shot.png", "my photo.png"] {
            try await commitFile(store, path: path, data: pngBytes)
            let content = await store.blobContent(path: path, at: "HEAD")
            XCTAssertEqual(content, pngBytes, path)
        }
    }
}
