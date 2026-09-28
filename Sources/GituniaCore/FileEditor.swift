import Foundation

/// Pure decision logic behind "Simple editing" (spec item 5): whether a working-tree file may be
/// edited in place, how to tell a genuinely concurrent on-disk edit apart from a no-op mtime touch
/// before saving, and how to write text edited in a `\n`-normalized text view back out preserving
/// the file's original line-ending style and trailing-newline presence. No file I/O happens here —
/// the view layer reads/writes disk and hands this type the facts to decide with, so every rule is
/// testable without touching a real file.
public enum FileEditor {
    /// Above this, "Edit" is disabled rather than loading a possibly-huge file into a plain,
    /// non-virtualized `TextEditor`.
    public static let maxEditableBytes = 1_000_000 // 1 MB

    public enum Editability: Equatable, Sendable {
        case editable
        case notEditable(reason: String)

        public var isEditable: Bool {
            if case .editable = self { return true }
            return false
        }

        public var reason: String? {
            if case .notEditable(let reason) = self { return reason }
            return nil
        }
    }

    /// - Parameters:
    ///   - fileExists: whether the working-tree copy exists on disk.
    ///   - isConflicted: whether this file has an unresolved merge/rebase conflict — those render
    ///     through `ConflictMarkupView` instead, never this editor.
    ///   - isImage: `FileChange.isImage` — image diffs render through `ImagePreviewView`.
    ///   - isSymlink: whether the working-tree path is itself a symlink (checked via `lstat`
    ///     semantics, never dereferenced) — a symlink can point anywhere on disk (e.g. `~/.ssh/
    ///     id_rsa`), so it's never editable and its target is never read through. Checked before
    ///     `fileSize`/`isValidUTF8`, which the caller must not compute by reading through the link.
    ///   - fileSize: size in bytes.
    ///   - isValidUTF8: whether the file's bytes decode as UTF-8 text.
    public static func editability(
        fileExists: Bool,
        isConflicted: Bool,
        isImage: Bool,
        isSymlink: Bool = false,
        fileSize: Int,
        isValidUTF8: Bool
    ) -> Editability {
        guard fileExists else { return .notEditable(reason: "File does not exist in the working tree") }
        guard !isConflicted else { return .notEditable(reason: "File has an unresolved conflict") }
        guard !isSymlink else { return .notEditable(reason: "This is a symlink") }
        guard !isImage else { return .notEditable(reason: "Image files can't be edited as text") }
        guard fileSize <= maxEditableBytes else {
            return .notEditable(reason: "File is larger than \(maxEditableBytes / 1_000_000) MB")
        }
        guard isValidUTF8 else { return .notEditable(reason: "File is not valid UTF-8 text") }
        return .editable
    }

    /// Whether `url` is itself a symlink, via `URLResourceValues.isSymbolicLink` — which, like
    /// `lstat`, reports on the link itself rather than following it. Callers must check this
    /// *before* sizing or reading the path (`FileManager.attributesOfItem`/`Data(contentsOf:)`
    /// both transparently dereference a symlink), otherwise a symlink such as
    /// `notes.txt -> ~/.ssh/id_rsa` would have its target's bytes read and, if displayed, disclosed
    /// under the innocuous working-tree name.
    public static func isSymlink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    // MARK: - Concurrent modification

    /// What the file looked like at some point in time, cheaply comparable without keeping the
    /// full content around.
    public struct Snapshot: Equatable, Sendable {
        public let modificationDate: Date
        public let contentHash: Int

        public init(modificationDate: Date, content: Data) {
            self.modificationDate = modificationDate
            var hasher = Hasher()
            hasher.combine(content)
            self.contentHash = hasher.finalize()
        }

        public init(modificationDate: Date, contentHash: Int) {
            self.modificationDate = modificationDate
            self.contentHash = contentHash
        }
    }

    public enum ConcurrentChange: Equatable, Sendable {
        /// Nothing changed on disk since load — safe to overwrite.
        case unchanged
        /// The mtime moved but the bytes are identical (e.g. a `touch`, or the filesystem
        /// re-stamping the file some other way) — treated the same as `.unchanged`, not a
        /// conflict.
        case mtimeOnlyChange
        /// The bytes actually differ — something else (an agent, most likely) wrote to this file.
        /// Ask before overwriting.
        case conflict
    }

    /// The pure decision behind the "this file changed on disk since you started editing" dialog:
    /// compares what was loaded against what's on disk right before a save.
    public static func concurrentChange(loaded: Snapshot, current: Snapshot) -> ConcurrentChange {
        guard loaded.contentHash == current.contentHash else { return .conflict }
        return loaded.modificationDate == current.modificationDate ? .unchanged : .mtimeOnlyChange
    }

    // MARK: - Line endings

    public enum LineEnding: Equatable, Sendable { case lf, crlf }

    /// A file's line-ending style and whether it ends with a trailing newline, captured on load so
    /// a save can restore both rather than silently normalizing the whole file to LF.
    public struct TextFormat: Equatable, Sendable {
        public let lineEnding: LineEnding
        public let hasTrailingNewline: Bool

        public init(lineEnding: LineEnding, hasTrailingNewline: Bool) {
            self.lineEnding = lineEnding
            self.hasTrailingNewline = hasTrailingNewline
        }

        /// Detects the dominant line ending (CRLF if any `\r\n` appears, else LF) and whether the
        /// text ends with a newline, from the file's original text — before it gets normalized to
        /// plain `\n` for the text view.
        public static func detect(in text: String) -> TextFormat {
            // `hasSuffix("\n")` on the raw text is a trap for a CRLF file: Swift's `String` treats
            // `"\r\n"` as a single `Character` (one grapheme cluster), so its last `Character` is
            // never `== "\n"` even though the file plainly ends with a newline. Normalizing first
            // sidesteps that.
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return TextFormat(lineEnding: text.contains("\r\n") ? .crlf : .lf, hasTrailingNewline: normalized.hasSuffix("\n"))
        }
    }

    /// Turns `\n`-normalized text from the editor back into the bytes to write to disk, restoring
    /// `format`'s line-ending style and trailing-newline presence instead of silently normalizing
    /// the whole file.
    public static func serialize(_ editedText: String, format: TextFormat) -> Data {
        var text = editedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if format.hasTrailingNewline {
            if !text.hasSuffix("\n") { text += "\n" }
        } else {
            while text.hasSuffix("\n") { text.removeLast() }
        }
        if format.lineEnding == .crlf {
            text = text.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return Data(text.utf8)
    }
}
