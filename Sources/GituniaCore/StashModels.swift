import Foundation

/// A `git stash list` row as the Stashes sheet shows it: `StashEntry` plus the stash commit's hash
/// and its date. The hash is the entry's identity — `stash@{n}` indexes shift whenever
/// anything (an agent, a terminal) stashes or drops, so every action re-checks that `ref` still
/// names `hash` before running (see `verifiedStashRef`).
public struct StashItem: Identifiable, Hashable, Sendable {
    public let entry: StashEntry
    public let hash: String
    public let date: Date
    public var id: String { hash }
    public var ref: String { "stash@{\(entry.index)}" }
    public init(entry: StashEntry, hash: String, date: Date) {
        self.entry = entry; self.hash = hash; self.date = date
    }
}

/// Parses `git stash list --format=%gd%x1f%H%x1f%ct%x1f%s` (unix time — shown via `RelativeDate`), reusing `StashParser` for the
/// selector/subject half so the "On <branch>:"/"WIP on <branch>:" split lives in one place.
public enum StashItemParser {
    public static let format = "%gd%x1f%H%x1f%ct%x1f%s"

    public static func parse(_ text: String) -> [StashItem] {
        text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard p.count == 4, let entry = StashParser.parse("\(p[0])\u{1f}\(p[3])").first,
                  let seconds = TimeInterval(p[2]) else { return nil }
            return StashItem(entry: entry, hash: String(p[1]), date: Date(timeIntervalSince1970: seconds))
        }
    }
}

/// Gitunia's own stash message: `gitunia: <repo> @ <branch> <yyyy-MM-ddTHH:mmZ>` (UTC). The
/// prefix is what `gituniaStashes()` and `StashMenu` recognise; branch names can't hold spaces,
/// so the last space and the last " @ " split it back unambiguously even if the repo name has them.
public enum StashLabel {
    public static let prefix = "gitunia: "

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return f
    }()

    public static func make(repo: String, branch: String, date: Date = Date()) -> String {
        "\(prefix)\(repo) @ \(branch) \(formatter.string(from: date))"
    }

    public static func parse(_ message: String) -> (branch: String, date: Date)? {
        guard message.hasPrefix(prefix), let space = message.lastIndex(of: " "),
              let date = formatter.date(from: String(message[message.index(after: space)...])),
              let at = message[..<space].range(of: " @ ", options: .backwards) else { return nil }
        let branch = String(message[at.upperBound..<space])
        return branch.isEmpty ? nil : (branch, date)
    }
}

extension StashItem {
    /// Branch + time from a Gitunia label, nil for any other stash.
    public var gituniaLabel: (branch: String, date: Date)? { StashLabel.parse(entry.message) }
}

/// Verified against git 2.50.1: an apply/pop that conflicts exits 1, leaves `UU` entries and
/// `.git/AUTO_MERGE` — but no `MERGE_HEAD` or any other operation file, so `operation` stays nil —
/// and keeps the stash entry even for pop ("The stash entry is kept in case you need it again.").
public enum StashApplyOutcome: Equatable, Sendable {
    case applied
    /// Number of files left conflicted. The entry was kept.
    case conflicts(Int)
    /// `lastError` carries git's message (e.g. local changes would be overwritten, or the entry
    /// moved since it was listed).
    case failed
}

public enum StashSelectedOutcome: Equatable, Sendable {
    case stashed
    case nothingToStash
    /// Files outside the selection have staged changes. Verified against git 2.50.1: a
    /// path-limited `stash push` still records the *whole index* in the stash, so those staged
    /// changes would silently ride along (and come back as modifications on apply) while also
    /// staying staged in the working tree. Refused rather than surprise the user.
    case otherFilesStaged([String])
    case failed
}

public enum RebaseOutcome: Equatable, Sendable {
    /// `autostashConflicted`: the rebase itself finished, but re-applying the auto-stashed changes
    /// conflicted — git exits 0, leaves `UU` files and keeps them as a stash entry named
    /// "autostash" (verified against git 2.50.1).
    case rebased(autostashConflicted: Bool)
    /// Stopped on conflicts; `operation == .rebase`, the operation banner takes over.
    case stoppedOnConflicts
    case failed
}

/// What rebasing the current branch onto `onto` would do, resolved before the confirmation
/// dialog so it can say it in plain words.
public struct RebasePlan: Equatable, Sendable {
    public let branch: String
    public let onto: String
    /// `onto..HEAD`: commits that get replayed (and new hashes).
    public let replayCount: Int
    /// Of those, how many the upstream already has — non-zero means a force push afterwards.
    public let pushedCount: Int
    /// `HEAD..onto`: zero means `onto` has nothing the branch lacks — nothing to rebase.
    public let newOnOnto: Int
    /// Tracked uncommitted changes (staged or not); untracked files don't block `git rebase`.
    public let dirtyCount: Int

    public init(branch: String, onto: String, replayCount: Int, pushedCount: Int, newOnOnto: Int, dirtyCount: Int) {
        self.branch = branch; self.onto = onto; self.replayCount = replayCount
        self.pushedCount = pushedCount; self.newOnOnto = newOnOnto; self.dirtyCount = dirtyCount
    }

    public var isUpToDate: Bool { newOnOnto == 0 }

    public var confirmTitle: String { "Rebase \(branch) onto \(onto)?" }

    public var confirmMessage: String {
        let n = replayCount
        var text = n == 0
            ? "\(branch) has no commits of its own, so it simply moves up to \(onto)."
            : "Your \(n) commit\(n == 1 ? "" : "s") on \(branch) will be replayed on top of \(onto), and \(n == 1 ? "it gets a new hash" : "each gets a new hash")."
        if pushedCount > 0 {
            text += " \(pushedCount == n ? (n == 1 ? "It is" : "They are") : "\(pushedCount) of them are") already pushed, so you'll need to force push afterwards."
        } else {
            text += " None of them are pushed yet, so nobody else is affected."
        }
        if dirtyCount > 0 {
            text += "\n\n\(dirtyCount) uncommitted change\(dirtyCount == 1 ? "" : "s") will be stashed first and put back when the rebase finishes."
        }
        return text
    }

    /// Hard stops, checked before the plan is even resolved. Uncommitted changes aren't one —
    /// the dialog offers to stash them (`git rebase --autostash`).
    public static func blocker(repo: Repository, operation: GitOperation?) -> String? {
        if !repo.isAvailable { return "Repository folder is missing or unavailable" }
        if let operation { return "A \(operation.label) is already in progress — finish or abort it first" }
        let conflicted = repo.changes.filter { $0.status == .conflicted }.count
        if conflicted > 0 { return "\(conflicted) file\(conflicted == 1 ? "" : "s") have unresolved conflicts" }
        if repo.branch == nil || repo.isDetached { return "Not on a branch (detached HEAD)" }
        return nil
    }
}
