import Foundation

/// One line of `git reflog` — where HEAD pointed after some action. `index` is the `n` in
/// `HEAD@{n}` (0 = newest).
public struct ReflogEntry: Identifiable, Hashable, Sendable {
    public let index: Int
    public let hash: String
    public let shortHash: String
    /// Everything before the first ": " of git's reflog subject, e.g. `commit (amend)`,
    /// `rebase (finish)`, `merge feat`, `pull --ff-only`.
    public let action: String
    /// Everything after it, e.g. `moving from main to feat`, or the commit subject.
    public let message: String
    public let date: Date
    public var id: Int { index }
    public var selector: String { "HEAD@{\(index)}" }
    /// First word of `action` — `commit`, `checkout`, `reset`, `rebase`, `merge`, `pull`,
    /// `cherry-pick`, `clone`… `commit (amend)` is reported as `amend`, since that's the one a
    /// reader scanning for "what rewrote my commit" needs to spot.
    public var kind: String {
        if action.hasPrefix("commit (amend)") { return "amend" }
        return String(action.prefix { $0 != " " && $0 != "(" })
    }

    public init(index: Int, hash: String, shortHash: String, action: String, message: String, date: Date) {
        self.index = index; self.hash = hash; self.shortHash = shortHash
        self.action = action; self.message = message; self.date = date
    }
}

/// Parses `git reflog --date=unix --format=%gd%x1f%H%x1f%h%x1f%gs%x1e`.
///
/// With `--date=unix`, `%gd` becomes `HEAD@{<unix time>}` instead of `HEAD@{<n>}` (verified
/// against git 2.50.1), so the timestamp comes from the selector and `n` is the record's position —
/// the reflog is printed newest first with no gaps. `%gs` is the reflog subject, always
/// `<action>: <message>` (e.g. `checkout: moving from main to feat`, `commit (amend): fix`,
/// `pull --ff-only: Fast-forward`, `rebase (finish): returning to refs/heads/feat`).
public enum ReflogParser {
    public static let format = "%gd%x1f%H%x1f%h%x1f%gs%x1e"

    public static func parse(_ text: String) -> [ReflogEntry] {
        var out: [ReflogEntry] = []
        for record in text.split(separator: "\u{1e}") {
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 else { continue }
            let stamp = f[0].split(separator: "{").last?.prefix { $0.isNumber }
            let date = Date(timeIntervalSince1970: TimeInterval(stamp.flatMap { Int($0) } ?? 0))
            let (action, message): (String, String)
            if let r = f[3].range(of: ": ") {
                (action, message) = (String(f[3][..<r.lowerBound]), String(f[3][r.upperBound...]))
            } else {
                (action, message) = (f[3], "")
            }
            out.append(ReflogEntry(index: out.count, hash: f[1], shortHash: f[2], action: action, message: message, date: date))
        }
        return out
    }
}

public enum ResetMode: String, CaseIterable, Sendable {
    case soft, mixed, hard

    public var title: String { rawValue.capitalized }

    /// Plain-words explanation shown next to each choice.
    public var explanation: String {
        switch self {
        case .soft: return "Commits are undone; their changes stay staged, ready to re-commit."
        case .mixed: return "Commits are undone; their changes stay in your files, unstaged."
        case .hard: return "Commits are undone and uncommitted changes are discarded — files match the chosen commit."
        }
    }
}

/// What resetting the current branch to a commit takes away from it.
public struct ResetImpact: Equatable, Sendable {
    /// Commits on the branch now that won't be after the reset (`<target>..HEAD`).
    public var undone: Int
    /// How many of those are already on some remote-tracking branch — undoing them means the next
    /// push needs a force push.
    public var pushed: Int
    public init(undone: Int, pushed: Int) { self.undone = undone; self.pushed = pushed }
}

extension Repository {
    /// `git status --porcelain=v2 --branch` prints `# branch.head (detached)` when HEAD is
    /// detached (verified against git 2.50.1), and `StatusParser` stores it verbatim.
    public var isDetached: Bool { branch == "(detached)" }

    /// The toolbar/sidebar name for HEAD: the branch, or "Detached at <short hash>".
    public var branchLabel: String {
        guard isDetached else { return branch ?? "—" }
        return headOID.map { "Detached at \($0.prefix(7))" } ?? "Detached HEAD"
    }

    /// `branchLabel`, but empty when there's no branch info at all (window subtitle).
    public var branchSubtitle: String { branch == nil ? "" : branchLabel }

    /// Tracked files a hard reset would discard. Untracked files survive `git reset --hard`, but a
    /// staged new file is deleted (both verified against git 2.50.1). Conflicted entries are listed
    /// too — they're uncommitted work as well.
    public var filesLostByHardReset: [String] {
        var seen = Set<String>()
        return changes.filter { $0.status != .untracked }.map(\.path).filter { seen.insert($0).inserted }
    }
}

extension Preflight {
    /// Resetting the current branch. Blocked while HEAD is detached (there's no branch to move —
    /// check out a commit instead) and while a merge/rebase/cherry-pick/revert is stopped: a reset
    /// in the middle of one leaves its state files behind and git's own guidance is to abort it.
    public static func checkReset(repo: Repository, operation: GitOperation?, impact: ResetImpact) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        if !repo.isAvailable {
            return [PreflightIssue(id: "unavailable", severity: .blocker, message: "Repository folder is missing or unavailable")]
        }
        if repo.isDetached {
            issues.append(PreflightIssue(id: "detached", severity: .blocker,
                                         message: "HEAD is detached — there's no branch to reset. Create a branch first."))
        }
        if let operation {
            issues.append(PreflightIssue(id: "operation-in-progress", severity: .blocker,
                                         message: "A \(operation.label) is in progress — continue or abort it first"))
        }
        if impact.pushed > 0 {
            issues.append(PreflightIssue(id: "reset-pushed", severity: .warning,
                                         message: "\(impact.pushed) of the \(impact.undone) undone commit\(impact.undone == 1 ? "" : "s") \(impact.pushed == 1 ? "is" : "are") already pushed — the remote keeps \(impact.pushed == 1 ? "it" : "them"), so your next push will need a force push."))
        }
        return issues
    }

    /// Switching away from a detached HEAD whose commits aren't on any branch, tag or remote —
    /// they'd survive only in the reflog. `orphanCount` is `RepositoryStore.commitsOnlyOnHead()`.
    public static func checkLeavingDetachedHead(repo: Repository, orphanCount: Int) -> PreflightIssue? {
        guard repo.isDetached, orphanCount > 0 else { return nil }
        return PreflightIssue(id: "detached-orphans", severity: .warning,
                              message: "\(orphanCount) commit\(orphanCount == 1 ? " was" : "s were") made on this detached HEAD and \(orphanCount == 1 ? "isn't" : "aren't") on any branch. Switching away leaves \(orphanCount == 1 ? "it" : "them") reachable only from the Reflog.")
    }
}
