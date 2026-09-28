import Foundation

/// Advisory checks run before a git-affecting action. Git remains the authority;
/// this only warns/blocks on cases the UI can explain better than a raw git error.
public enum PreflightAction: Sendable {
    case checkout(branch: String)
    case pull
    case push
    /// `git push --force-with-lease` on the current upstream. Distinct from `.push` because its
    /// blocker/warning rules are the opposite shape: no "nothing to push" warning (a force push
    /// makes sense even with nothing new authored, e.g. after an amend/undo), no upstream is a
    /// hard blocker (a first push is never forced — there's nothing to overwrite), and being behind
    /// is the whole point of the warning, spelled out plainly rather than as "may be rejected".
    case forcePush
    case commit
    /// Amending is a materially different action from a plain commit — it has no "nothing
    /// staged" blocker (amending to just reword is legitimate) but gains a "no commits yet"
    /// blocker and an "already pushed" warning — so it gets its own case rather than a
    /// parameter on `.commit` that would force every commit-site switch to handle both shapes.
    case amend
    /// `hasParent` is whether HEAD has a parent commit. `Preflight.check` is pure and can't run
    /// `git rev-parse HEAD~1` itself, so `RepositoryStore` resolves it (refreshed alongside
    /// `hasUpstream`) and passes it in here, the same way `hasUpstream` itself is threaded through.
    case undoLastCommit(hasParent: Bool)
    /// `git merge --no-edit <branch>` — merging `branch` into the current one. No stash-and-switch
    /// style override: unlike checkout, stashing first doesn't make a merge safe to retry (the
    /// merge itself, not the branch switch, is what the uncommitted changes would collide with), so
    /// this is a plain blocker rather than one the toolbar can offer a stash shortcut for.
    case mergeBranch(branch: String)
}

public struct PreflightIssue: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable { case blocker, warning }

    public let id: String
    public let severity: Severity
    public let message: String
    /// Large-file warnings only: the `git lfs track` pattern the message suggests (e.g. `*.bin`).
    public var suggestedLFSPattern: String?

    public init(id: String, severity: Severity, message: String, suggestedLFSPattern: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.suggestedLFSPattern = suggestedLFSPattern
    }
}

public enum Preflight {
    /// `pull --ff-only` can never succeed once a branch has both local and remote commits it
    /// doesn't share — the UI checks this *before* calling pull so it can offer the rebase/merge
    /// choice instead of running a command already known to fail. Pure arithmetic over the ahead/
    /// behind counts `refreshStatus()` already parses from `git status --branch`.
    public static func isDiverged(repo: Repository) -> Bool {
        repo.ahead > 0 && repo.behind > 0
    }

    /// One warning per *staged* file whose known size exceeds `threshold`. The size is the
    /// working-tree size, not the staged blob's — close enough for a heads-up. LFS-tracked paths
    /// are skipped (git stores a tiny pointer); with LFS rules or `git lfs` installed the message
    /// names a concrete `git lfs track` pattern instead of the generic advice.
    public static func largeFileWarnings(in changes: [FileChange], threshold: Int = 5_000_000,
                                         rules: [AttributeRule] = [], lfsInstalled: Bool = false) -> [PreflightIssue] {
        let suggestLFS = lfsInstalled || rules.contains { $0.attributes["filter"] == "lfs" }
        return changes.compactMap { change in
            guard change.area == .staged, let size = change.size, size > threshold,
                  !GitAttributes.isLFSTracked(change.path, rules: rules) else { return nil }
            let ext = (change.path as NSString).pathExtension
            let pattern = ext.isEmpty ? change.path : "*.\(ext)"
            let advice = suggestLFS ? "consider `git lfs track '\(pattern)'`" : "consider Git LFS or .gitignore"
            return PreflightIssue(id: "large-file:\(change.path)", severity: .warning,
                                  message: "\(change.path) is \(Int64(size).formatted(.byteCount(style: .file))) — large files bloat the repository forever; \(advice)",
                                  suggestedLFSPattern: suggestLFS ? pattern : nil)
        }
    }

    // ponytail: substring heuristic for agent-authored identities; a per-workspace allow/deny list if it misfires.
    static let botEmailMarkers = ["noreply@anthropic", "bot@", "agent@", "[bot]"]
    static let botNameMarkers = ["bot", "agent", "claude"]

    /// `nil` (not loaded yet) yields nothing. Missing name/email blocks — git would refuse anyway.
    /// The signing note is a `.warning` with id `"signing"` (there's no info severity); callers
    /// that gate on warnings should skip it.
    public static func identityWarnings(_ id: CommitIdentity?) -> [PreflightIssue] {
        guard let id else { return [] }
        let name = id.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let email = id.email?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if name.isEmpty || email.isEmpty {
            return [PreflightIssue(id: "no-identity", severity: .blocker,
                                   message: "No git identity — set user.name and user.email")]
        }
        var issues: [PreflightIssue] = []
        let lowerName = name.lowercased()
        if botEmailMarkers.contains(where: email.contains)
            || (email.hasSuffix("@users.noreply.github.com") && botNameMarkers.contains(where: lowerName.contains)) {
            issues.append(PreflightIssue(id: "bot-identity", severity: .warning,
                                         message: "Committing as \(name) <\(email)> — this looks like a bot/agent identity"))
        }
        if id.signingEnabled {
            issues.append(PreflightIssue(id: "signing", severity: .warning,
                                         message: "Commits will be signed with \(id.signingFormat ?? "openpgp") key \(id.signingKey ?? "(default)")"))
        }
        return issues
    }

    /// `operationInProgress` is only consulted by `.mergeBranch` (merge/rebase/cherry-pick/revert
    /// already stopped on conflicts) — every other call site omits it, same as `hasParentCommit` is
    /// threaded through only for `.undoLastCommit`.
    public static func check(_ action: PreflightAction, repo: Repository, hasUpstream: Bool, operationInProgress: Bool = false) -> [PreflightIssue] {
        var blockers: [PreflightIssue] = []
        var warnings: [PreflightIssue] = []

        if !repo.isAvailable {
            blockers.append(PreflightIssue(id: "unavailable", severity: .blocker,
                                            message: "Repository folder is missing or unavailable"))
            return blockers
        }

        let conflicted = repo.changes.filter { $0.status == .conflicted }

        switch action {
        case .checkout(let branch):
            // Staged changes are as uncommitted as unstaged ones from checkout's point of
            // view — both are silently carried to the target branch — so they count too.
            let uncommitted = Set(repo.changes.map(\.path)).count
            if uncommitted > 0 {
                blockers.append(PreflightIssue(id: "uncommitted", severity: .blocker,
                                                message: "\(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s") will follow you to \(branch)"))
            }
            if !conflicted.isEmpty {
                blockers.append(PreflightIssue(id: "conflicted", severity: .blocker,
                                                message: "\(conflicted.count) file\(conflicted.count == 1 ? "" : "s") have unresolved conflicts"))
            }

        case .pull:
            if !hasUpstream {
                blockers.append(PreflightIssue(id: "no-upstream", severity: .blocker,
                                                message: "No upstream branch configured"))
            }
            if !conflicted.isEmpty {
                blockers.append(PreflightIssue(id: "conflicted", severity: .blocker,
                                                message: "\(conflicted.count) file\(conflicted.count == 1 ? "" : "s") have unresolved conflicts"))
            }
            if hasUpstream && repo.behind == 0 {
                warnings.append(PreflightIssue(id: "nothing-to-pull", severity: .warning, message: "Nothing to pull"))
            }

        case .push:
            if hasUpstream && repo.ahead == 0 {
                warnings.append(PreflightIssue(id: "nothing-to-push", severity: .warning, message: "Nothing to push"))
            }
            if repo.behind > 0 {
                warnings.append(PreflightIssue(id: "behind", severity: .warning,
                                                message: "\(repo.behind) commit\(repo.behind == 1 ? "" : "s") behind — push may be rejected"))
            }

        case .forcePush:
            if !hasUpstream {
                blockers.append(PreflightIssue(id: "no-upstream", severity: .blocker,
                                                message: "No upstream branch — a first push is never forced"))
            } else if repo.behind > 0 {
                warnings.append(PreflightIssue(id: "behind", severity: .warning,
                                                message: "You will discard \(repo.behind) commit\(repo.behind == 1 ? "" : "s") on the remote"))
            }

        case .commit:
            let staged = repo.changes.contains { $0.area == .staged }
            if !staged {
                blockers.append(PreflightIssue(id: "nothing-staged", severity: .blocker, message: "Nothing staged"))
            }
            warnings += largeFileWarnings(in: repo.changes)

        case .amend:
            // `refreshStatus` leaves `lastCommitSummary` nil when `git log -1` fails, which is
            // exactly the empty-repo case — reused here instead of a second `git` round trip.
            if repo.lastCommitSummary == nil {
                blockers.append(PreflightIssue(id: "no-commits", severity: .blocker,
                                                message: "No commits yet — nothing to amend"))
            } else if hasUpstream && repo.ahead == 0 {
                // ahead == 0 with an upstream means HEAD matches the remote-tracking ref, so the
                // last commit is already on the remote. With ahead > 0 it's still only local and
                // amending is safe. This can go stale if the remote-tracking ref hasn't been
                // refreshed since a fetch/pull/push (e.g. someone else force-pushed and we haven't
                // fetched) — the warning reflects what Gitunia last observed, not a live check.
                warnings.append(PreflightIssue(id: "amend-pushed", severity: .warning,
                                                message: "This commit has already been pushed. Amending rewrites history the remote already has — the next push will be rejected, and this app never force-pushes to fix that."))
            }

        case .undoLastCommit(let hasParent):
            if !hasParent {
                blockers.append(PreflightIssue(id: "no-parent", severity: .blocker,
                                                message: "This is the repository's first commit — there is no parent to reset to"))
            } else if hasUpstream && repo.ahead == 0 {
                // Blocker here, warning for the equivalent case on `.amend` — deliberately not the
                // same severity. Amending leaves a commit in place at HEAD, reworded; the remote
                // divergence it creates is easy to reason about and the user is already mid-edit
                // when they hit it. Undo removes the commit from history outright the moment this
                // runs — the branch tip jumps back before the user has seen anything change — so a
                // slip here is more surprising and harder to notice immediately. That earns the
                // toolbar's blocker-with-override treatment (an explicit "do it anyway") rather
                // than a warning that lets the action proceed on the first click.
                blockers.append(PreflightIssue(id: "undo-pushed", severity: .blocker,
                                                message: "This commit has already been pushed. Undoing it rewrites history the remote already has — the next push will be rejected, and this app never force-pushes to fix that."))
            }

        case .mergeBranch(let branch):
            let uncommitted = Set(repo.changes.map(\.path)).count
            if uncommitted > 0 {
                blockers.append(PreflightIssue(id: "uncommitted", severity: .blocker,
                                                message: "\(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s") — commit or discard them before merging \(branch)"))
            }
            if operationInProgress {
                blockers.append(PreflightIssue(id: "operation-in-progress", severity: .blocker,
                                                message: "Another operation is already in progress — resolve or abort it first"))
            }
            if !conflicted.isEmpty {
                blockers.append(PreflightIssue(id: "conflicted", severity: .blocker,
                                                message: "\(conflicted.count) file\(conflicted.count == 1 ? "" : "s") have unresolved conflicts"))
            }
        }

        return blockers + warnings
    }
}
