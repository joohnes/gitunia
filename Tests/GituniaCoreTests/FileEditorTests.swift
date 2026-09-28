import XCTest
@testable import GituniaCore

final class FileEditorTests: XCTestCase {
    // MARK: - Editability

    func testEditable_whenFileExistsAndIsSmallValidText() {
        let result = FileEditor.editability(fileExists: true, isConflicted: false, isImage: false, fileSize: 10, isValidUTF8: true)
        XCTAssertEqual(result, .editable)
        XCTAssertTrue(result.isEditable)
    }

    func testNotEditable_whenFileMissing() {
        let result = FileEditor.editability(fileExists: false, isConflicted: false, isImage: false, fileSize: 10, isValidUTF8: true)
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.reason, "File does not exist in the working tree")
    }

    func testNotEditable_whenConflicted() {
        let result = FileEditor.editability(fileExists: true, isConflicted: true, isImage: false, fileSize: 10, isValidUTF8: true)
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.reason, "File has an unresolved conflict")
    }

    func testNotEditable_whenImage() {
        let result = FileEditor.editability(fileExists: true, isConflicted: false, isImage: true, fileSize: 10, isValidUTF8: true)
        XCTAssertFalse(result.isEditable)
    }

    func testNotEditable_whenOverSizeCap() {
        let result = FileEditor.editability(
            fileExists: true, isConflicted: false, isImage: false,
            fileSize: FileEditor.maxEditableBytes + 1, isValidUTF8: true
        )
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.reason, "File is larger than 1 MB")
    }

    func testEditable_atExactlySizeCap() {
        let result = FileEditor.editability(
            fileExists: true, isConflicted: false, isImage: false,
            fileSize: FileEditor.maxEditableBytes, isValidUTF8: true
        )
        XCTAssertTrue(result.isEditable)
    }

    func testNotEditable_whenNotValidUTF8() {
        let result = FileEditor.editability(fileExists: true, isConflicted: false, isImage: false, fileSize: 10, isValidUTF8: false)
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.reason, "File is not valid UTF-8 text")
    }

    // MARK: - Symlinks (M9)

    func testNotEditable_whenSymlink() {
        let result = FileEditor.editability(fileExists: true, isConflicted: false, isImage: false, isSymlink: true, fileSize: 10, isValidUTF8: true)
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.reason, "This is a symlink")
    }

    /// Symlink wins over every other guard — even a file that would otherwise look editable (or
    /// even conflicted/image) must never fall through to a size/content check that would read
    /// through the link.
    func testNotEditable_whenSymlink_takesPriorityOverOtherwiseEditable() {
        let result = FileEditor.editability(fileExists: true, isConflicted: false, isImage: false, isSymlink: true, fileSize: 0, isValidUTF8: true)
        XCTAssertEqual(result.reason, "This is a symlink")
    }

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

    func testIsSymlink_regularFile_isFalse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-symlink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(FileEditor.isSymlink(at: file))
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

    func testSnapshot_hashDerivedFromContent_matchesForIdenticalBytes() {
        let a = FileEditor.Snapshot(modificationDate: Date(), content: Data("hello".utf8))
        let b = FileEditor.Snapshot(modificationDate: Date(), content: Data("hello".utf8))
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testSnapshot_hashDiffersForDifferentBytes() {
        let a = FileEditor.Snapshot(modificationDate: Date(), content: Data("hello".utf8))
        let b = FileEditor.Snapshot(modificationDate: Date(), content: Data("goodbye".utf8))
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    // MARK: - Line ending / trailing newline detection

    func testDetectFormat_lfWithTrailingNewline() {
        let format = FileEditor.TextFormat.detect(in: "one\ntwo\n")
        XCTAssertEqual(format.lineEnding, .lf)
        XCTAssertTrue(format.hasTrailingNewline)
    }

    func testDetectFormat_lfWithoutTrailingNewline() {
        let format = FileEditor.TextFormat.detect(in: "one\ntwo")
        XCTAssertEqual(format.lineEnding, .lf)
        XCTAssertFalse(format.hasTrailingNewline)
    }

    func testDetectFormat_crlfWithTrailingNewline() {
        let format = FileEditor.TextFormat.detect(in: "one\r\ntwo\r\n")
        XCTAssertEqual(format.lineEnding, .crlf)
        XCTAssertTrue(format.hasTrailingNewline)
    }

    func testDetectFormat_crlfWithoutTrailingNewline() {
        let format = FileEditor.TextFormat.detect(in: "one\r\ntwo")
        XCTAssertEqual(format.lineEnding, .crlf)
        XCTAssertFalse(format.hasTrailingNewline)
    }

    func testDetectFormat_emptyText_defaultsToLFNoTrailingNewline() {
        let format = FileEditor.TextFormat.detect(in: "")
        XCTAssertEqual(format.lineEnding, .lf)
        XCTAssertFalse(format.hasTrailingNewline)
    }

    // MARK: - Serialization (preserving line endings / trailing newline)

    func testSerialize_preservesLFWithTrailingNewline() {
        let format = FileEditor.TextFormat(lineEnding: .lf, hasTrailingNewline: true)
        let data = FileEditor.serialize("one\ntwo", format: format)
        XCTAssertEqual(String(data: data, encoding: .utf8), "one\ntwo\n")
    }

    func testSerialize_preservesNoTrailingNewline() {
        let format = FileEditor.TextFormat(lineEnding: .lf, hasTrailingNewline: false)
        let data = FileEditor.serialize("one\ntwo\n", format: format)
        XCTAssertEqual(String(data: data, encoding: .utf8), "one\ntwo")
    }

    func testSerialize_restoresCRLF() {
        let format = FileEditor.TextFormat(lineEnding: .crlf, hasTrailingNewline: true)
        let data = FileEditor.serialize("one\ntwo\n", format: format)
        XCTAssertEqual(String(data: data, encoding: .utf8), "one\r\ntwo\r\n")
    }

    func testSerialize_crlfWithoutTrailingNewline() {
        let format = FileEditor.TextFormat(lineEnding: .crlf, hasTrailingNewline: false)
        let data = FileEditor.serialize("one\ntwo\n", format: format)
        XCTAssertEqual(String(data: data, encoding: .utf8), "one\r\ntwo")
    }

    /// Text from a plain `\n`-normalized text view should never end up double-newlined even when
    /// the editor's own text already happens to end with `\n` and the format also wants one.
    func testSerialize_doesNotDoubleTrailingNewline() {
        let format = FileEditor.TextFormat(lineEnding: .lf, hasTrailingNewline: true)
        let data = FileEditor.serialize("one\ntwo\n", format: format)
        XCTAssertEqual(String(data: data, encoding: .utf8), "one\ntwo\n")
    }

    /// Round-trip: detect a CRLF-no-trailing-newline file, edit it via plain `\n` text, serialize —
    /// should come back out CRLF, no trailing newline.
    func testRoundTrip_crlfNoTrailingNewline() {
        let original = "line1\r\nline2\r\nline3"
        let format = FileEditor.TextFormat.detect(in: original)
        let normalized = original.replacingOccurrences(of: "\r\n", with: "\n")
        let data = FileEditor.serialize(normalized, format: format)
        XCTAssertEqual(String(data: data, encoding: .utf8), original)
    }
}
