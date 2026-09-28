import Foundation

/// One `git grep` match: repo-relative path, 1-based line number, the matched line's text.
public struct GrepHit: Hashable, Sendable {
    public let path: String
    public let line: Int
    public let text: String
    public init(path: String, line: Int, text: String) { self.path = path; self.line = line; self.text = text }
}

public enum WorkspaceSearch {
    /// Parses `git grep -n -z` output: `path\0line\0text` per line. NUL separators (not `:`) so a
    /// colon in the path or the matched text can't split a field; lines without them (e.g.
    /// "Binary file x matches", should `-I` ever be dropped) are skipped.
    public static func parseGrep(_ output: String) -> [GrepHit] {
        output.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[1]) else { return nil }
            return GrepHit(path: String(parts[0]), line: line, text: String(parts[2]))
        }
    }
}

extension RepositoryStore {
    /// Working tree + untracked files (not ignored), literal match (`-F`), text files only (`-I`).
    /// Exit 1 is git grep's "no matches", not a failure.
    public func grep(_ query: String, limit: Int = 200) async -> [GrepHit] {
        let out = try? await git.run(["grep", "-n", "-z", "-I", "-F", "--untracked", "-e", query], in: url, allowedExitCodes: [0, 1])
        return Array(WorkspaceSearch.parseGrep(out ?? "").prefix(limit))
    }

    /// Pickaxe: the last 20 commits whose diff adds or removes `query`.
    public func commitsTouching(_ query: String) async -> [CommitInfo] {
        await history(limit: 20, filterArgs: ["-S\(query)"])
    }
}
