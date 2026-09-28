import XCTest
@testable import GituniaCore

final class FileHistoryParserTests: XCTestCase {
    func testAddedModifiedDeletedRenamed() {
        XCTAssertEqual(FileHistoryChangeKind.parse(["A", "new.txt"])?.kind, .added)
        XCTAssertEqual(FileHistoryChangeKind.parse(["M", "x.txt"])?.kind, .modified)
        XCTAssertEqual(FileHistoryChangeKind.parse(["D", "gone.txt"])?.kind, .deleted)
        XCTAssertEqual(FileHistoryChangeKind.parse(["R100", "old.txt", "new.txt"])?.kind, .renamed)
        XCTAssertEqual(FileHistoryChangeKind.parse(["R100", "old.txt", "new.txt"])?.path, "new.txt")
    }

    func testRecordWithEmailParsesIt() {
        let entries = FileHistoryParser.parse("\u{1e}abc\u{1f}ab\u{1f}Bot\u{1f}2026-01-01\u{1f}s\u{1f}p1\u{1f}bot@x.io\n\nM\ta.txt\n")
        XCTAssertEqual(entries.first?.authorEmail, "bot@x.io")
        XCTAssertEqual(entries.first?.path, "a.txt")
    }

    func testRecordWithoutEmailStillParses() {
        let entries = FileHistoryParser.parse("\u{1e}abc\u{1f}ab\u{1f}Al\u{1f}2026-01-01\u{1f}s\u{1f}p1\n\nM\ta.txt\n")
        XCTAssertEqual(entries.first?.commit.author, "Al")
        XCTAssertEqual(entries.first?.authorEmail, "")
    }

    func testMalformedLineReturnsNil() {
        XCTAssertNil(FileHistoryChangeKind.parse([]))
        XCTAssertNil(FileHistoryChangeKind.parse(["A"]))
    }

    // MARK: - C3: --name-status real git output for C-quoted paths

    /// Real `git -c core.quotePath=false log --name-status` on a rename to a filename containing a
    /// tab — verified: `R100␉orig.txt␉"with\ttab.txt"` (the same quoting rule as porcelain v2,
    /// applied to each path field independently).
    func testNameStatusParserDecodesQuotedRenamedPath() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("hello\nworld\n", to: repo, "orig.txt")
        _ = try await GitRunner().run(["add", "orig.txt"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "orig"], in: repo)
        _ = try await GitRunner().run(["mv", "orig.txt", "with\ttab.txt"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "rename"], in: repo)
        let out = try await GitRunner().run(["diff", "-M", "--name-status", "HEAD~1", "HEAD"], in: repo)
        let result = NameStatusParser.parse(out)
        XCTAssertEqual(result["with\ttab.txt"], .renamed)
        XCTAssertNil(result["\"with\\ttab.txt\""]) // must not still be the literal quoted form
    }

    /// Real `--name-status` for a new file with a literal quote in its name — verified:
    /// `A␉"with\"quote.txt"`.
    func testNameStatusParserDecodesQuotedAddedPath() async throws {
        let repo = try await TestHelpers.makeTempRepo()
        try TestHelpers.write("x\n", to: repo, "with\"quote.txt")
        _ = try await GitRunner().run(["add", "-A"], in: repo)
        _ = try await GitRunner().run(["commit", "-q", "-m", "add"], in: repo)
        let out = try await GitRunner().run(["diff", "--name-status", "HEAD~1", "HEAD"], in: repo)
        let result = NameStatusParser.parse(out)
        XCTAssertEqual(result["with\"quote.txt"], .added)
    }
}
