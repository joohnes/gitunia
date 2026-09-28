import Foundation

/// What a `--name-status` line says happened to a path in one commit — just enough to answer "did
/// this file exist before this commit" (only `.added` means no), not a full status model (that's
/// `FileChange.Status`, which is about the working tree, not history).
public enum FileHistoryChangeKind: Equatable, Sendable {
    case added, modified, deleted, renamed

    /// Parses one `--name-status` line already split on tabs, e.g. `["M", "a.txt"]` or
    /// `["R100", "a.txt", "b.txt"]` — the status code first, then one path (or two, for a rename).
    /// Returns the path this commit's diff of "just this file" should use: for a rename that's the
    /// new name (the file's identity *at* this commit, after the rename); for everything else it's
    /// the only path given. `nil` for a malformed/empty line.
    static func parse(_ fields: [Substring]) -> (kind: FileHistoryChangeKind, path: String)? {
        guard let code = fields.first, let last = fields.last, fields.count >= 2 else { return nil }
        let path = GitQuotedPath.decode(String(last))
        if code.hasPrefix("A") { return (.added, path) }
        if code.hasPrefix("D") { return (.deleted, path) }
        if code.hasPrefix("R") { return (.renamed, path) }
        return (.modified, path) // M, C (copy), T (typechange) — all "the file existed before".
    }
}

/// One entry in a file's history — the commit plus the path that file had *in that commit*.
/// `--follow` only works for a single starting path, so a rename's older entries carry the file's
/// old name, not the name `RepositoryStore.fileHistory` was called with.
public struct FileHistoryEntry: Identifiable, Equatable, Sendable {
    public let commit: CommitInfo
    public let path: String
    public let kind: FileHistoryChangeKind
    public var id: String { commit.hash }
    public var authorEmail: String { commit.authorEmail }

    public init(commit: CommitInfo, path: String, kind: FileHistoryChangeKind) {
        self.commit = commit; self.path = path; self.kind = kind
    }
}

/// Parses `git log --follow --name-status --pretty=format:%x1e\(LogParser.fields) --date=short -- <path>`. The `%x1e` is *leading* (unlike `LogParser`'s trailing one) because
/// each record here has a multi-line body (the `--name-status` line(s) git appends after every
/// commit's pretty output) — splitting on a trailing separator would glue one commit's body onto
/// the next commit's header. Verified against real git (2.50.1) in a temp repo with a rename: a
/// rename commit's body line reads `R100\t<old>\t<new>`, every other commit's reads `<code>\t<path>`,
/// and git prints exactly one such line per record for a single followed path (`FileHistoryTests`).
public enum FileHistoryParser {
    public static func parse(_ text: String) -> [FileHistoryEntry] {
        text.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
            guard let headerLine = lines.first,
                  let commit = LogParser.commit(fields: headerLine.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)),
                  let statusLine = lines.dropFirst().first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let (kind, path) = FileHistoryChangeKind.parse(statusLine.split(separator: "\t"))
            else { return nil }
            return FileHistoryEntry(commit: commit, path: path, kind: kind)
        }
    }
}

/// Parses a plain `--name-status` listing (no commit header) into a `path -> kind` map — used by
/// `RepositoryStore.commitFileStatuses` so `CommitDiffView`'s file list (not just file-history
/// entries) can also tell "this commit added the file" apart from "modified/deleted/renamed",
/// which is what decides whether "Restore Version Before This Commit" makes sense for a given file.
public enum NameStatusParser {
    public static func parse(_ text: String) -> [String: FileHistoryChangeKind] {
        var result: [String: FileHistoryChangeKind] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (kind, path) = FileHistoryChangeKind.parse(line.split(separator: "\t")) else { continue }
            result[path] = kind
        }
        return result
    }
}

/// Whether restoring `path`'s working-tree copy would discard uncommitted changes to it — a pure
/// function over the repo's current `changes` list, so `RestoreFileRunner`'s confirmation wording
/// (and this logic itself) is testable without shelling out. Any entry for `path` — staged,
/// unstaged, or untracked-at-that-name-after-a-prior-discard — counts, matching how `git restore
/// --worktree` would overwrite whatever's on disk regardless of what's staged.
public enum RestoreFileConfirmation {
    public static func hasUncommittedChanges(path: String, in changes: [FileChange]) -> Bool {
        changes.contains { $0.path == path }
    }
}
