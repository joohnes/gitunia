import XCTest
@testable import GituniaCore

final class FileEditorTests: XCTestCase {
    // MARK: - Editability

    func testNotEditable_whenNotValidUTF8() {
        let result = FileEditor.editability(fileExists: true, isConflicted: false, isImage: false, fileSize: 10, isValidUTF8: false)
        XCTAssertFalse(result.isEditable)
    }

    // MARK: - Symlinks (M9)

    /// `isSymlink(at:)` uses `lstat` semantics (`URLResourceValues.isSymbolicLink`), not
    /// `FileManager.fileExists`/`attributesOfItem`, which would transparently follow the link.
    /// Verified against a real symlink (pointing at a real, readable target) in a temp dir, so this
    /// exercises the actual filesystem call rather than a mocked resource-value lookup.
    func testIsSymlink_realSymlinkInTempDir_detectedWithoutFollowing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-symlink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("secret.txt")
        try "top secret".write(to: target, atomically: true, encoding: .utf8)

        let link = dir.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(FileEditor.isSymlink(at: link))
        XCTAssertFalse(FileEditor.isSymlink(at: target))

        // Feeding that straight into `editability` (as `DiffView.fileEditability` does) must reject
        // it before any size/content check runs, regardless of what those would say.
        let result = FileEditor.editability(
            fileExists: true, isConflicted: false, isImage: false, isSymlink: true, fileSize: 0, isValidUTF8: true
        )
        XCTAssertEqual(result, .notEditable(reason: "This is a symlink"))
    }

    // MARK: - Concurrent modification

    func testConcurrentChange_unchanged_sameHashSameMTime() {
        let date = Date()
        let loaded = FileEditor.Snapshot(modificationDate: date, contentHash: 42)
        let current = FileEditor.Snapshot(modificationDate: date, contentHash: 42)
        XCTAssertEqual(FileEditor.concurrentChange(loaded: loaded, current: current), .unchanged)
    }

    /// mtime moved (e.g. a `touch`, or the filesystem re-stamping the file) but the bytes are
    /// identical — must not be treated as a conflict.
    func testConcurrentChange_mtimeOnlyChange_treatedAsUnchanged() {
        let loaded = FileEditor.Snapshot(modificationDate: Date(timeIntervalSince1970: 0), contentHash: 42)
        let current = FileEditor.Snapshot(modificationDate: Date(timeIntervalSince1970: 1000), contentHash: 42)
        XCTAssertEqual(FileEditor.concurrentChange(loaded: loaded, current: current), .mtimeOnlyChange)
    }

    func testConcurrentChange_contentDiffers_isConflict() {
        let date = Date()
        let loaded = FileEditor.Snapshot(modificationDate: date, contentHash: 1)
        let current = FileEditor.Snapshot(modificationDate: date, contentHash: 2)
        XCTAssertEqual(FileEditor.concurrentChange(loaded: loaded, current: current), .conflict)
    }

    /// Even if the mtime also moved, differing content is still a conflict — mtime alone never
    /// overrides a real content difference.
    func testConcurrentChange_contentDiffersAndMTimeDiffers_isStillConflict() {
        let loaded = FileEditor.Snapshot(modificationDate: Date(timeIntervalSince1970: 0), contentHash: 1)
        let current = FileEditor.Snapshot(modificationDate: Date(timeIntervalSince1970: 1000), contentHash: 2)
        XCTAssertEqual(FileEditor.concurrentChange(loaded: loaded, current: current), .conflict)
    }

    // MARK: - Serialization (preserving line endings / trailing newline)

    /// Editor text is `\n`-normalized; serialization restores the file's line ending and trailing
    /// newline, and never doubles a trailing `\n` the text already has.
    func testSerialize() {
        let cases: [(text: String, ending: FileEditor.LineEnding, trailing: Bool, expected: String)] = [
            ("one\ntwo", .lf, true, "one\ntwo\n"),
            ("one\ntwo\n", .lf, false, "one\ntwo"),
            ("one\ntwo\n", .crlf, true, "one\r\ntwo\r\n"),
            ("one\ntwo\n", .crlf, false, "one\r\ntwo"),
            ("one\ntwo\n", .lf, true, "one\ntwo\n"),
        ]
        for c in cases {
            let format = FileEditor.TextFormat(lineEnding: c.ending, hasTrailingNewline: c.trailing)
            let data = FileEditor.serialize(c.text, format: format)
            XCTAssertEqual(String(data: data, encoding: .utf8), c.expected, "\(c.text.debugDescription) \(c.ending) trailing=\(c.trailing)")
        }

        // Round-trip: detect a CRLF-no-trailing-newline file, edit it via plain `\n` text, serialize.
        let original = "line1\r\nline2\r\nline3"
        let format = FileEditor.TextFormat.detect(in: original)
        let normalized = original.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(String(data: FileEditor.serialize(normalized, format: format), encoding: .utf8), original)
    }
}
