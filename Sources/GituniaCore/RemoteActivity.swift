import Foundation

/// Remote-tracking refs (`origin/feat-x` → oid) at one moment — the "before" and "after" of a fetch.
public struct RemoteRefSnapshot: Equatable, Sendable {
    public var refs: [String: String]
    public var takenAt: Date
    public init(refs: [String: String], takenAt: Date = Date()) { self.refs = refs; self.takenAt = takenAt }
}

public enum ActivityEventKind: String, Codable, Sendable {
    case branchCreated, branchUpdated, branchDeleted, baseAdvanced, pullRequestMerged, forcePushed
}

public struct ActivityCommit: Codable, Equatable, Sendable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public let subject: String
    public let author: String
    public let authorEmail: String
    public let date: Date
    public init(hash: String, subject: String, author: String, authorEmail: String, date: Date) {
        self.hash = hash; self.subject = subject; self.author = author; self.authorEmail = authorEmail; self.date = date
    }
}

/// Something that happened on a remote between two fetches.
public struct ActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let repoPath: String
    public let repoName: String
    public let kind: ActivityEventKind
    /// e.g. `"origin/feat-x"`.
    public let ref: String
    public let oldOID: String?
    public let newOID: String?
    /// New commits on this ref, newest first, capped at 50.
    public let commits: [ActivityCommit]
    public let pullRequestNumber: Int?
    public let pullRequestTitle: String?
    public let date: Date
    public var seen: Bool

    public init(id: UUID = UUID(), repoPath: String, repoName: String, kind: ActivityEventKind, ref: String,
                oldOID: String?, newOID: String?, commits: [ActivityCommit] = [], pullRequestNumber: Int? = nil,
                pullRequestTitle: String? = nil, date: Date = Date(), seen: Bool = false) {
        self.id = id; self.repoPath = repoPath; self.repoName = repoName; self.kind = kind; self.ref = ref
        self.oldOID = oldOID; self.newOID = newOID; self.commits = commits
        self.pullRequestNumber = pullRequestNumber; self.pullRequestTitle = pullRequestTitle
        self.date = date; self.seen = seen
    }
}

/// Pure parsing/diffing behind remote activity tracking — see `RepositoryStore+Activity`.
public enum RemoteActivity {
    /// `git for-each-ref --format='%(refname:lstrip=2) %(objectname)' refs/remotes` (or `refname:short`).
    /// Skips the `<remote>/HEAD` symref (which `refname:short` abbreviates to a bare `origin`).
    public static func parseRefs(_ forEachRefOutput: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in forEachRefOutput.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            guard name.contains("/"), !name.hasSuffix("/HEAD") else { continue }
            refs[name] = String(parts[1])
        }
        return refs
    }

    /// Sorted by ref. `.forcePushed` and `.pullRequestMerged` need git and are decided by the store.
    public static func diff(old: RemoteRefSnapshot, new: RemoteRefSnapshot, baseRef: String?)
        -> [(kind: ActivityEventKind, ref: String, oldOID: String?, newOID: String?)] {
        Set(old.refs.keys).union(new.refs.keys).sorted().compactMap { ref in
            let o = old.refs[ref], n = new.refs[ref]
            switch (o, n) {
            case (nil, let n?): return (.branchCreated, ref, nil, n)
            case (let o?, nil): return (.branchDeleted, ref, o, nil)
            case (let o?, let n?) where o != n: return (ref == baseRef ? .baseAdvanced : .branchUpdated, ref, o, n)
            default: return nil
            }
        }
    }

    /// `"Merge pull request #123 from x/y"` → 123; `"feat: add x (#45)"` → 45; else nil.
    public static func pullRequestNumber(inSubject subject: String) -> Int? {
        let s = subject.trimmingCharacters(in: .whitespaces)
        let merge = "Merge pull request #"
        if s.hasPrefix(merge) { return Int(s.dropFirst(merge.count).prefix { $0.isNumber }) }
        if s.hasSuffix(")"), let open = s.range(of: "(#", options: .backwards) {
            return Int(s[open.upperBound..<s.index(before: s.endIndex)])
        }
        return nil
    }

    /// The PR title a squash subject carries (`"feat: add x (#45)"` → `"feat: add x"`); nil for merge commits.
    static func squashTitle(_ subject: String) -> String? {
        guard !subject.hasPrefix("Merge pull request #"), let open = subject.range(of: " (#", options: .backwards) else { return nil }
        return String(subject[..<open.lowerBound])
    }

    public static let logFormat = "%H%x1f%s%x1f%an%x1f%ae%x1f%aI"

    /// `git log --format=%H%x1f%s%x1f%an%x1f%ae%x1f%aI` output.
    public static func parseCommits(_ logOutput: String) -> [ActivityCommit] {
        let iso = ISO8601DateFormatter()
        return logOutput.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            return ActivityCommit(hash: f[0], subject: f[1], author: f[2], authorEmail: f[3], date: iso.date(from: f[4]) ?? Date())
        }
    }
}
