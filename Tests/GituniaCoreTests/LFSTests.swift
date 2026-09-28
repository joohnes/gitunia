import XCTest
@testable import GituniaCore

@MainActor
final class LFSTests: XCTestCase {
    /// No `git lfs` needed: rules come from reading `.gitattributes`, re-read when its mtime moves.
    func testRefreshStatusPicksUpGitattributes() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertTrue(store.attributeRules.isEmpty)
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(to: url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        await store.refreshStatus()
        XCTAssertTrue(GitAttributes.isLFSTracked("a.bin", rules: store.attributeRules))
        XCTAssertEqual(store.attributeRules.first?.pattern, "*.bin")
    }

    /// A fake `git-lfs` on PATH (`lfsPathOverride`) stands in for the real one, so this exercises
    /// `checkLFSInstalled`/`lfsTrack` end to end without depending on the test machine having Git LFS.
    private static let fakeGitLFS = """
    #!/bin/sh
    case "$1" in
      version) echo "git-lfs/3.4.0 (fake)" ;;
      track) echo "$2 filter=lfs diff=lfs merge=lfs -text" >> .gitattributes ;;
    esac
    """

    func testFakeGitLFSTracksThroughRealPath() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let bin = try TestHelpers.makeTempDir()
        let path = bin.appendingPathComponent("git-lfs").path
        try Self.fakeGitLFS.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let store = RepositoryStore(url: url)
        store.lfsPathOverride = bin.path
        let installed = await store.checkLFSInstalled()
        XCTAssertTrue(installed)

        let error = await store.lfsTrack("*.psd")
        XCTAssertNil(error, error?.stderr ?? "")
        XCTAssertTrue(GitAttributes.isLFSTracked("art/a.psd", rules: store.attributeRules))
    }
}
