import XCTest
@testable import GituniaCore

/// T4: `git clean` preview/delete and `.gitignore` append — pure parsing/building logic plus
/// `RepositoryStore` against real temp repos, same style as `BranchOpsTests`/`RemoteOpsTests`.
final class GitignorePatternTests: XCTestCase {
    func testFilePatternEscapesGlobCharacters() {
        XCTAssertEqual(GitignorePattern.file("a[1]*.txt"), "/a\\[1]\\*.txt")
        XCTAssertEqual(GitignorePattern.folder("odd "), "/odd\\ /")
    }
}

final class GitignoreEditorTests: XCTestCase {
    func testAppendsWithoutTrailingNewline() {
        XCTAssertEqual(GitignoreEditor.appending("*.log", to: "/build/"), "/build/\n*.log\n")
    }

    func testDedupesExistingLine() {
        XCTAssertNil(GitignoreEditor.appending("*.log", to: "/build/\n*.log\n"))
    }

    func testDoesNotTreatSubstringAsDuplicate() {
        XCTAssertEqual(GitignoreEditor.appending("*.log", to: "debug.log\n"), "debug.log\n*.log\n")
    }
}

final class CleanRepositoryStoreTests: XCTestCase {
    @MainActor
    func testPreviewWithoutDirectories() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("junk", to: url, "junk.txt")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("build"), withIntermediateDirectories: true)
        try TestHelpers.write("obj", to: url, "build/obj.o")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: false)
        XCTAssertEqual(preview, ["junk.txt"])
    }

    @MainActor
    func testPreviewWithDirectories() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("junk", to: url, "junk.txt")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("build"), withIntermediateDirectories: true)
        try TestHelpers.write("obj", to: url, "build/obj.o")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: true)
        XCTAssertEqual(preview.sorted(), ["build/", "junk.txt"])
    }

    @MainActor
    func testIgnoredFilesNeverAppearInPreview() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("*.log\n", to: url, ".gitignore")
        try TestHelpers.write("noisy", to: url, "debug.log")
        try TestHelpers.write("junk", to: url, "junk.txt")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: false)
        XCTAssertEqual(preview.sorted(), [".gitignore", "junk.txt"])
    }

    /// The core "exactly what was previewed" guarantee: an untracked file that shows up *after*
    /// the preview was taken (an agent writing mid-review, say) must survive `clean(paths:)` even
    /// though a fresh `clean -n` would now also offer to remove it.
    @MainActor
    func testCleanDeletesOnlyThePreviewedPaths() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("junk", to: url, "junk.txt")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: false)
        XCTAssertEqual(preview, ["junk.txt"])

        // Simulate a file appearing after the preview but before the user confirms.
        try TestHelpers.write("late", to: url, "late.txt")

        let ok = await store.clean(paths: preview, includeDirectories: false)
        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("junk.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("late.txt").path))
    }

    /// A previewed name with glob characters must not act as a pattern: `a[1].txt` as a plain
    /// pathspec also matches `a1.txt`, which appeared after the preview and was never shown.
    @MainActor
    func testCleanTreatsPreviewedPathsLiterally() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("x", to: url, "a[1].txt")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: false)
        XCTAssertEqual(preview, ["a[1].txt"])
        try TestHelpers.write("late", to: url, "a1.txt")

        let ok = await store.clean(paths: preview, includeDirectories: false)
        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("a[1].txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("a1.txt").path))
    }

    @MainActor
    func testCleanWithDirectoriesRemovesWholeDirectory() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try FileManager.default.createDirectory(at: url.appendingPathComponent("build"), withIntermediateDirectories: true)
        try TestHelpers.write("obj", to: url, "build/obj.o")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: true)
        XCTAssertEqual(preview, ["build/"])
        let ok = await store.clean(paths: preview, includeDirectories: true)
        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("build").path))
    }
}

final class GitignoreRepositoryStoreTests: XCTestCase {
    @MainActor
    func testCleanRemovesFileWhoseNameGitQuotes() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("x", to: url, "weird\"name.txt")
        let store = RepositoryStore(url: url)
        let preview = await store.cleanPreview(includeDirectories: false)
        XCTAssertEqual(preview, ["weird\"name.txt"])
        _ = await store.clean(paths: preview, includeDirectories: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("weird\"name.txt").path))
    }
}
