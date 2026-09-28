import XCTest
@testable import GituniaCore

/// `headPatch()` feeds the amend-time secret scan in `CommitBox` when nothing is staged (B12):
/// a secret already committed at HEAD must still be caught.
@MainActor
final class RepositoryStoreHeadPatchTests: XCTestCase {
    func testHeadPatchSurfacesSecretAlreadyCommitted() async throws {
        let url = try await TestRepo.make(files: ["config/aws.env": "AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP\n"])
        let store = RepositoryStore(url: url)
        let patch = await store.headPatch()
        let findings = SecretScanner.findings(inLog: patch)
        XCTAssertEqual(findings.map { ($0.path, $0.label) }.map { "\($0.0):\($0.1)" }, ["config/aws.env:an AWS access key ID"])
    }
}
