import Foundation

/// Parses `git clean -n`'s output. Verified against real git in `CleanOpsTests`: every line is
/// `Would remove <path>` — a directory (only listed at all when `-d` was passed) keeps a trailing
/// `/`, a plain file doesn't. Lines that don't match that prefix (there shouldn't be any) are
/// dropped rather than guessed at.
public enum CleanPreviewParser {
    private static let prefix = "Would remove "

    public static func parse(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count))
        }
    }
}

/// Builds a `.gitignore` pattern for the three "Ignore" submenu choices — pure and testable apart
/// from any file I/O, which `RepositoryStore.addToGitignore` handles separately.
public enum GitignorePattern {
    /// `/<path>` — anchored to the repo root so the pattern only ever matches this one file.
    public static func file(_ path: String) -> String { "/" + escaped(path) }

    /// `/<path>/` — anchored and trailing-slashed so it only matches a directory. `path` is the
    /// folder's own repo-relative path: callers pass the file's parent for "Ignore This Folder" on
    /// a file row, or the directory's own path for a directory row.
    public static func folder(_ path: String) -> String { "/" + escaped(path) + "/" }

    /// Glob characters in a real name are escaped so "this file" never also ignores its
    /// look-alikes (`a[1].txt` would otherwise match `a1.txt`). Leading `#`/`!` are already
    /// harmless behind the anchoring `/`.
    static func escaped(_ path: String) -> String {
        var out = ""
        for c in path {
            if "\\*?[".contains(c) { out.append("\\") }
            out.append(c)
        }
        if out.hasSuffix(" ") { out.insert("\\", at: out.index(before: out.endIndex)) }
        return out
    }

    /// `*.<ext>` for `path`'s extension, or `nil` when it has none (a dotfile like `.env`, or a
    /// plain extensionless name) — the "All *.ext Files" menu item is omitted in that case.
    public static func extensionGlob(for path: String) -> String? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return "*.\(ext)"
    }
}

/// Pure append-and-dedupe logic for `.gitignore`, kept separate from `RepositoryStore` so it's
/// testable without a temp repo.
public enum GitignoreEditor {
    /// Appends `pattern` as its own line to `contents`, ensuring a trailing newline first.
    /// Returns `nil` (no change) when `pattern` already appears as an exact line — never a
    /// substring/prefix match, so `*.log` doesn't get treated as already covering `debug.log`.
    public static func appending(_ pattern: String, to contents: String) -> String? {
        let existingLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        if existingLines.contains(where: { $0 == Substring(pattern) }) { return nil }
        var result = contents
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        result += pattern + "\n"
        return result
    }
}
