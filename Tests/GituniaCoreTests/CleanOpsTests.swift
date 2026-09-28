import XCTest
@testable import GituniaCore

/// T4: `git clean` preview/delete and `.gitignore` append — pure parsing/building logic plus
/// `RepositoryStore` against real temp repos, same style as `BranchOpsTests`/`RemoteOpsTests`.
final class CleanPreviewParserTests: XCTestCase {
    func testParsesFilesOnly() {
        let out = "Would remove .DS_Store\nWould remove build.log\n"
        XCTAssertEqual(CleanPreviewParser.parse(out), [".DS_Store", "build.log"])
    }

    func testParsesDirectoriesWithTrailingSlash() {
        let out = "Would remove build/\nWould remove master.o\n"
        XCTAssertEqual(CleanPreviewParser.parse(out), ["build/", "master.o"])
    }

    func testEmptyOutputIsEmpty() {
        XCTAssertEqual(CleanPreviewParser.parse(""), [])
    }
}

final class GitignorePatternTests: XCTestCase {
    func testFilePattern() {
        XCTAssertEqual(GitignorePattern.file("src/master.swift"), "/src/master.swift")
    }

    func testFilePatternEscapesGlobCharacters() {
        XCTAssertEqual(GitignorePattern.file("a[1]*.txt"), "/a\\[1]\\*.txt")
        XCTAssertEqual(GitignorePattern.folder("odd "), "/odd\\ /")
    }

    func testFolderPattern() {
        XCTAssertEqual(GitignorePattern.folder("build"), "/build/")
    }

    func testExtensionPattern() {
        XCTAssertEqual(GitignorePattern.extensionGlob(for: "src/master.swift"), "*.swift")
    }

    func testNoExtensionOmitsPattern() {
        XCTAssertNil(GitignorePattern.extensionGlob(for: "README"))
    }

    func testDotfileOmitsPattern() {
        XCTAssertNil(GitignorePattern.extensionGlob(for: ".env"))
    }
}

final class GitignoreEditorTests: XCTestCase {
    func testCreatesWithTrailingNewline() {
        XCTAssertEqual(GitignoreEditor.appending("/build/", to: ""), "/build/\n")
    }

    func testAppendsAfterTrailingNewline() {
        XCTAssertEqual(GitignoreEditor.appending("*.log", to: "/build/\n"), "/build/\n*.log\n")
    }

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
    func testCreatesGitignoreWhenMissing() async throws {
        let url = try await TestHelpers.makeTempRepo()
        let store = RepositoryStore(url: url)
        let ok = await store.addToGitignore("/build/")
        XCTAssertTrue(ok)
        let contents = try String(contentsOf: url.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(contents, "/build/\n")
    }

    @MainActor
    func testAppendsWithoutTrailingNewlineInExistingFile() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("*.log", to: url, ".gitignore") // deliberately no trailing newline
        let store = RepositoryStore(url: url)
        let ok = await store.addToGitignore("/build/")
        XCTAssertTrue(ok)
        let contents = try String(contentsOf: url.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(contents, "*.log\n/build/\n")
    }

    @MainActor
    func testDoesNotDuplicateExistingLine() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("/build/\n", to: url, ".gitignore")
        let store = RepositoryStore(url: url)
        let ok = await store.addToGitignore("/build/")
        XCTAssertFalse(ok)
        let contents = try String(contentsOf: url.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(contents, "/build/\n")
    }

    @MainActor
    func testIgnoredUntrackedFileDisappearsAfterRefresh() async throws {
        let url = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("junk", to: url, "junk.txt")
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        XCTAssertTrue(store.untrackedChanges.map(\.path).contains("junk.txt"))

        _ = await store.addToGitignore(GitignorePattern.file("junk.txt"))
        // addToGitignore already refreshes; assert directly rather than refreshing again so a
        // regression that dropped that refresh call fails this test instead of hiding behind a
        // second, redundant refresh here.
        XCTAssertFalse(store.untrackedChanges.map(\.path).contains("junk.txt"))
    }
}
