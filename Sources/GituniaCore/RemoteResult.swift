import Foundation

public enum RemoteKind: String, Sendable {
    case fetch, pull, push
    /// Not a remote op — only here so `WorkspaceStore.stashAll` can reuse the bulk machinery
    /// (`BulkOperation.kind`, the sidebar's "Stashing… n/m" strip).
    case stash
}

public struct RemoteResult: Sendable {
    public let kind: RemoteKind
    public let succeeded: Bool
    public let summary: String
    public let error: GitError?

    public init(kind: RemoteKind, succeeded: Bool, summary: String, error: GitError? = nil) {
        self.kind = kind; self.succeeded = succeeded; self.summary = summary; self.error = error
    }

    /// True when nothing actually changed (already up to date / everything up-to-date).
    public var isNoOp: Bool {
        guard succeeded else { return false }
        let s = summary.localizedLowercase
        return s.contains("up to date") || s.contains("up-to-date")
    }

    /// Classifies a *failed* result's stderr into something the UI can act on (offer a rebase/merge
    /// choice, offer a force-push toast action, explain a lease rejection) rather than just showing
    /// the raw git error. `.other` for a succeeded result or any failure that isn't one of the
    /// specific cases below.
    public var failureKind: RemoteFailureKind {
        guard !succeeded, let stderr = error?.stderr else { return .other }
        switch kind {
        case .pull: return RemoteOutputParser.pullFailureKind(stderr: stderr)
        case .push: return RemoteOutputParser.pushFailureKind(stderr: stderr)
        case .fetch, .stash: return .other
        }
    }
}

/// See `RemoteResult.failureKind`. Wording is matched against git's actual stderr, captured from a
/// real temp repo (see `RemoteOutputParserTests`) rather than guessed.
public enum RemoteFailureKind: Sendable, Equatable {
    /// `pull --ff-only` refused because the branch has diverged (ahead and behind both > 0).
    case diverged
    /// A plain `push` was rejected because the remote has commits this branch doesn't.
    case nonFastForward
    /// `push --force-with-lease` was rejected because the remote moved since the last fetch —
    /// the lease is stale, so forcing would silently overwrite commits never seen locally.
    case leaseStale
    /// Plain `git push` couldn't pick a destination branch: no upstream (or the app's cached
    /// `hasUpstream` was stale), or the upstream's name differs from the local branch's.
    /// `RepositoryStore.push()` retries these with `--set-upstream`.
    case noUpstream
    /// The repository has no remote at all.
    case noRemote
    case other
}

/// Turns git's raw stdout+stderr from fetch/pull/push into a short human-facing summary.
/// Pure over strings so it's trivially testable — git writes most of this to stderr, so
/// callers must pass both streams (see `GitRunner.runCombined`).
public enum RemoteOutputParser {
    /// Gitunia's own stderr when a push finds no remote — classified as `.noRemote` above.
    public static let noRemoteMessage = "No remote configured."

    public static func summary(for kind: RemoteKind, stdout: String, stderr: String, remote: String = "origin") -> String {
        let combined = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .fetch: return fetchSummary(combined)
        case .pull: return pullSummary(combined)
        case .push: return pushSummary(combined, remote: remote)
        case .stash: return combined
        }
    }

    private static func fetchSummary(_ text: String) -> String {
        if text.isEmpty { return "Already up to date" }
        // "From <remote>" header, one ref-update line per changed ref.
        let refLines = text.split(separator: "\n").filter { !$0.hasPrefix("From ") }
        if refLines.isEmpty { return "Already up to date" }
        return refLines.count == 1 ? "Fetched 1 ref" : "Fetched \(refLines.count) refs"
    }

    private static func pullSummary(_ text: String) -> String {
        if text.hasPrefix("Already up to date") { return "Already up to date" }
        // Fast-forward prints a diffstat footer like " 3 files changed, 12 insertions(+), 4 deletions(-)".
        // Git doesn't state the commit count directly, so report the diffstat instead.
        if let statLine = text.split(separator: "\n").first(where: { $0.contains(" file") && $0.contains("changed") }) {
            let filesPart = statLine.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? statLine.trimmingCharacters(in: .whitespaces)
            return "Pulled — \(filesPart)"
        }
        return "Pulled"
    }

    /// `git pull --ff-only` on a diverged branch prints (to stderr) "Diverging branches can't be
    /// fast-forwarded" as a hint, then fails with "fatal: Not possible to fast-forward, aborting." —
    /// verified against real git output in a temp repo (`RemoteOutputParserTests`), not guessed.
    public static func pullFailureKind(stderr: String) -> RemoteFailureKind {
        stderr.contains("Not possible to fast-forward") ? .diverged : .other
    }

    /// A plain push rejection prints `! [rejected]  <branch> -> <branch> (fetch first)` (or
    /// `(non-fast-forward)` in older git); `--force-with-lease` rejected by a stale remote-tracking
    /// ref prints `(stale info)` instead. Both verified against real git output.
    public static func pushFailureKind(stderr: String) -> RemoteFailureKind {
        if stderr.contains("(stale info)") { return .leaseStale }
        if stderr.contains("[rejected]") { return .nonFastForward }
        if stderr.contains("has no upstream branch") || stderr.contains("does not match\nthe name of your current branch") {
            return .noUpstream
        }
        if stderr.contains("No configured push destination") || stderr.hasPrefix(noRemoteMessage) { return .noRemote }
        return .other
    }

    private static func pushSummary(_ text: String, remote: String) -> String {
        if text.hasPrefix("Everything up-to-date") { return "Everything up-to-date" }
        // " * [new branch]      HEAD -> main" or "   abc1234..def5678  main -> main"
        let updateLine = text.split(separator: "\n").first { $0.contains("->") }
        if let updateLine, let arrowRange = updateLine.range(of: "->") {
            let dest = updateLine[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let branch = dest.split(separator: " ").first.map(String.init) ?? dest
            return "Pushed to \(remote)/\(branch)"
        }
        return "Pushed"
    }
}
