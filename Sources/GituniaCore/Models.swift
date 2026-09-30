import CryptoKit
import Foundation

public struct Repository: Identifiable, Hashable, Sendable {
    public let id: URL
    public var name: String
    public var branch: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [FileChange] { didSet { changeCount = Self.distinctPaths(changes) } }
    public var lastCommitSummary: String? = nil
    /// HEAD's `%an` / `%ae`, from the same `git log` as `lastCommitSummary`.
    public var lastCommitAuthor: String? = nil
    public var lastCommitEmail: String? = nil
    public var tags: Set<String>
    public var localAIOnly: Bool
    public var isAvailable = true
    /// HEAD's commit hash from `# branch.oid` (`"(initial)"` before the first commit).
    public var headOID: String? = nil

    public init(id: URL, name: String? = nil, branch: String? = nil, ahead: Int = 0, behind: Int = 0,
                changes: [FileChange] = [], tags: Set<String> = [], localAIOnly: Bool = false) {
        self.id = id
        self.name = name ?? id.lastPathComponent
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.changeCount = Self.distinctPaths(changes)
        self.tags = tags
        self.localAIOnly = localAIOnly
    }

    /// Number of distinct changed paths (a file staged and unstaged counts once). Stored, kept in
    /// sync by `changes`' `didSet` — the sidebar reads it for every row on every render.
    public private(set) var changeCount = 0
    private static func distinctPaths(_ changes: [FileChange]) -> Int { Set(changes.map(\.path)).count }
    public var hasChanges: Bool { !changes.isEmpty }
    /// HEAD plus the working-tree state, hashed — changes when an agent commits or edits, but not on
    /// fetch (ahead/behind are left out). Drives the sidebar's unseen dot and "Recent activity".
    public var fingerprint: String {
        let text = ([headOID ?? ""] + changes.map { "\($0.area.rawValue)\($0.status.rawValue)\($0.path)" }.sorted()).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable { case modified, added, deleted, renamed, untracked, conflicted }
    public enum Area: String, Sendable { case staged, unstaged }

    public let path: String
    public let oldPath: String?
    public let status: Status
    public let area: Area
    /// Working-tree size in bytes, filled by `RepositoryStore.refreshStatus` for untracked/added/
    /// modified files only; nil for deleted files, other statuses, or when sizing was skipped.
    public var size: Int?

    /// Stored rather than interpolated per read: `List`/`ForEach` read it for every row on every diff.
    public let id: String

    public init(path: String, oldPath: String? = nil, status: Status, area: Area, size: Int? = nil) {
        self.id = "\(area.rawValue):\(path)"
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.area = area
        self.size = size
    }

    /// Hashes the id only (it's derived from `area` + `path`, so still consistent with the
    /// synthesized `==`): `List` selection sets hash every row, and the full struct is five strings.
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var isImage: Bool {
        let kind = PreviewKind.kind(for: path)
        return kind == .raster || kind == .vector
    }
}

public struct StatusResult: Equatable, Sendable {
    public var branch: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [FileChange]
    public var headOID: String? = nil
    public init(branch: String? = nil, ahead: Int = 0, behind: Int = 0, changes: [FileChange] = []) {
        self.branch = branch; self.ahead = ahead; self.behind = behind; self.changes = changes
    }
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case added, removed, context }
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    /// A "\ No newline at end of file" marker followed this line: it is the last line of its side
    /// (old for removed, new for added, both for context) and has no trailing newline.
    public var noNewline: Bool
    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, noNewline: Bool = false) {
        self.kind = kind; self.text = text; self.oldNumber = oldNumber; self.newNumber = newNumber
        self.noNewline = noNewline
    }
}

public struct Hunk: Hashable, Sendable {
    public let header: String
    public let lines: [DiffLine]
    public var isClipped: Bool
    public init(header: String, lines: [DiffLine], isClipped: Bool = false) {
        self.header = header; self.lines = lines; self.isClipped = isClipped
    }
}

public struct FileDiff: Hashable, Sendable {
    public let path: String
    public let isBinary: Bool
    public let hunks: [Hunk]
    public init(path: String, isBinary: Bool, hunks: [Hunk]) {
        self.path = path; self.isBinary = isBinary; self.hunks = hunks
    }
}

public struct CommitMessage: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public init(title: String = "", body: String = "") { self.title = title; self.body = body }

    /// Full message as passed to `git commit -F -`.
    public var fullText: String {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? title : "\(title)\n\n\(b)"
    }

    /// Both fields blank after trimming — used to decide whether a draft is worth persisting.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct BranchInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool
    /// `main`/`master` (or `origin/main` etc.) — pinned first in every branch picker. Stored, not
    /// computed: pickers ask it of every branch on every pass, and repos can have thousands.
    public let isDefaultBranch: Bool
    public var id: String { name }
    public init(name: String, isCurrent: Bool, isRemote: Bool) {
        self.name = name; self.isCurrent = isCurrent; self.isRemote = isRemote
        let short = name.lastIndex(of: "/").map { name[name.index(after: $0)...] } ?? name[...]
        self.isDefaultBranch = short == "main" || short == "master"
    }
}

extension Array where Element == BranchInfo {
    /// Local branches split for pickers: the default branch(es) first, then the rest in git's order.
    public var localPinnedFirst: (pinned: [BranchInfo], rest: [BranchInfo]) {
        var pinned: [BranchInfo] = [], rest: [BranchInfo] = []
        for branch in self where !branch.isRemote {
            if branch.isDefaultBranch { pinned.append(branch) } else { rest.append(branch) }
        }
        return (pinned, rest)
    }
}

public struct CommitInfo: Identifiable, Hashable, Sendable {
    public let hash: String
    public let shortHash: String
    public let author: String
    public let date: String
    public let subject: String
    /// Number of parents (from `%P`) — 1 for an ordinary commit, 0 for the root commit, 2+ for a
    /// merge commit. `RepositoryStore.revertCommit` needs this to decide whether `-m 1` is required.
    public let parentCount: Int
    /// `%ae` — only `RepositoryStore.history` asks for it (for `AgentProfile`); "" elsewhere.
    public var authorEmail: String = ""
    public var id: String { hash }
    public init(hash: String, shortHash: String, author: String, date: String, subject: String, parentCount: Int = 1, authorEmail: String = "") {
        self.hash = hash; self.shortHash = shortHash; self.author = author; self.date = date; self.subject = subject
        self.parentCount = parentCount; self.authorEmail = authorEmail
    }
}

/// Full detail for one commit's header in `CommitDiffView` — subject/body, author and committer
/// (name, email, date), and parent hashes (both full and short, same order, `%P`/`%p`).
public struct CommitDetail: Equatable, Sendable {
    public let hash: String
    public let subject: String
    public let body: String
    public let authorName: String
    public let authorEmail: String
    public let authorDate: String
    public let committerName: String
    public let committerEmail: String
    public let committerDate: String
    public let parents: [String]
    public let parentsShort: [String]

    public init(hash: String, subject: String, body: String, authorName: String, authorEmail: String,
                authorDate: String, committerName: String, committerEmail: String, committerDate: String,
                parents: [String], parentsShort: [String]) {
        self.hash = hash; self.subject = subject; self.body = body
        self.authorName = authorName; self.authorEmail = authorEmail; self.authorDate = authorDate
        self.committerName = committerName; self.committerEmail = committerEmail; self.committerDate = committerDate
        self.parents = parents; self.parentsShort = parentsShort
    }

    /// Whether the committer differs from the author — the header shows the committer line only
    /// when this is true (e.g. after a rebase or an amend by someone else).
    public var committerDiffersFromAuthor: Bool {
        authorName != committerName || authorEmail != committerEmail || authorDate != committerDate
    }
}

/// One entry from `git stash list`.
public struct StashEntry: Identifiable, Hashable, Sendable {
    public let index: Int
    public let branch: String
    public let message: String
    public var id: Int { index }
    public init(index: Int, branch: String, message: String) {
        self.index = index; self.branch = branch; self.message = message
    }
}

/// The four operations git can be stopped in the middle of — generalises the old separate
/// `mergeInProgress`/`rebaseInProgress` booleans on `RepositoryStore`. `nil` (no case) means none is
/// in progress. Detected purely from files/directories under `.git` (see
/// `RepositoryStore.refreshOperationState`), never from a git subprocess.
public enum GitOperation: String, Sendable, Equatable, CaseIterable {
    /// `bisect` isn't stopped on conflicts — it's detected from `BISECT_LOG` (checked last) and
    /// driven from History's `BisectPanel`, not the Continue/Skip banner.
    case merge, rebase, cherryPick, revert, bisect

    /// Lowercase noun for messages ("a rebase is in progress").
    public var label: String {
        switch self {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        case .bisect: return "bisect"
        }
    }
}

public struct GitError: Error, LocalizedError, Sendable {
    public let args: [String]
    public let exitCode: Int32
    public let stderr: String
    public init(args: [String], exitCode: Int32, stderr: String) {
        // Remote URLs can embed credentials; never keep them in anything that gets displayed.
        self.args = args.map(URLRedaction.redact); self.exitCode = exitCode; self.stderr = URLRedaction.redact(stderr)
    }
    /// `git <args>` as typed in a terminal — for showing which command failed.
    public var commandLine: String { (["git"] + args).joined(separator: " ") }
    public var errorDescription: String? {
        "git \(args.joined(separator: " ")) failed (\(exitCode))\n\(stderr)"
    }
}
