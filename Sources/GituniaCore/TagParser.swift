import Foundation

/// A git tag (`refs/tags/*`) — not to be confused with `Repository.tags`, which are this app's own
/// free-form repo labels (`TagEditorSheet`).
public struct GitTag: Identifiable, Hashable, Sendable {
    public let name: String
    /// The commit the tag points at — for an annotated tag, the peeled commit, not the tag object.
    public let commitHash: String
    public let isAnnotated: Bool
    /// Annotated tags only; `nil` for lightweight ones (whose `%(contents)` is the commit's message).
    public let message: String?
    public var id: String { name }

    public init(name: String, commitHash: String, isAnnotated: Bool, message: String?) {
        self.name = name; self.commitHash = commitHash; self.isAnnotated = isAnnotated; self.message = message
    }
}

/// Parses `git for-each-ref refs/tags --format=<TagParser.format>`. Real output (git 2.x): each
/// record is `refs/tags/<name>␟<objectname>␟<*objectname>␟<objecttype>␟<contents>␞\n`.
/// A lightweight tag has objecttype `commit` and an empty `*objectname`, and `%(contents)` then
/// yields the *commit's* message — so the message is only kept for `tag` objects.
public enum TagParser {
    public static let format = "%(refname)%1f%(objectname)%1f%(*objectname)%1f%(objecttype)%1f%(contents)%1e"

    public static func parse(_ text: String) -> [GitTag] {
        text.split(separator: "\u{1e}").compactMap { record in
            let f = record.drop(while: { $0 == "\n" }).split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, f[0].hasPrefix("refs/tags/") else { return nil }
            let annotated = f[3] == "tag"
            let message = f[4].trimmingCharacters(in: .whitespacesAndNewlines)
            return GitTag(name: String(f[0].dropFirst("refs/tags/".count)),
                          commitHash: annotated && !f[2].isEmpty ? f[2] : f[1],
                          isAnnotated: annotated,
                          message: annotated && !message.isEmpty ? message : nil)
        }
    }

    /// Commit hash → tag names on it, built once per load so History rows never call git per row.
    public static func byCommit(_ tags: [GitTag]) -> [String: [String]] {
        Dictionary(grouping: tags, by: \.commitHash).mapValues { $0.map(\.name).sorted() }
    }
}

/// Result of creating a tag or a branch at a commit — validation happens before git runs so the
/// caller can word a specific reason.
public enum RefCreateOutcome: Sendable, Equatable {
    case succeeded
    case invalidName(String)
    case duplicateName
    case failed(String)
}

/// `RepositoryStore.deleteMergedBranches` — which went and which git refused (with its reason).
public struct MergedCleanupResult: Sendable, Equatable {
    public let deleted: [String]
    public let refused: [(name: String, reason: String)]

    public init(deleted: [String], refused: [(name: String, reason: String)]) {
        self.deleted = deleted; self.refused = refused
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.deleted == b.deleted && a.refused.map(\.name) == b.refused.map(\.name) && a.refused.map(\.reason) == b.refused.map(\.reason)
    }
}
