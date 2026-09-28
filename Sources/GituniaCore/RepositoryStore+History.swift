import Foundation

extension RepositoryStore {
    // MARK: - History

    /// `branch`, when given, shows that branch's history instead of the current branch (`HEAD`) —
    /// the branch picker at the top of `HistoryView`. `skip` pages past already-loaded commits
    /// (`HistoryView`'s "Load more"). `filterArgs` (from `HistoryFilter.gitArgs`) are inserted
    /// before `--date=short`, since `HistoryFilter`'s own `-- <path>` must stay the trailing
    /// argument — matches how git requires pathspecs to come last.
    public func history(limit: Int = 200, skip: Int = 0, branch: String? = nil, filterArgs: [String] = []) async -> [CommitInfo] {
        // A revision starting with `-` would parse as an option (`--output=<file>` writes a file).
        guard branch?.hasPrefix("-") != true else { return [] }
        var args = ["log", branch ?? "HEAD", "-n", "\(limit)"]
        if skip > 0 { args += ["--skip", "\(skip)"] }
        args += ["--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1f%ae%x1e", "--date=short"]
        // filterArgs last: `HistoryFilter.gitArgs` ends with `-- <path>` when a path filter is
        // set, and git treats everything after `--` as a pathspec — including `--pretty`/`--date`
        // if they came after it.
        args += filterArgs
        let out = try? await git.run(args, in: url)
        return LogParser.parse(out ?? "")
    }

    /// A single commit's `CommitInfo` by hash — used to jump to a parent commit clicked in
    /// `CommitDiffView`'s header without needing it to already be in `HistoryView`'s loaded pages.
    public func commitInfo(_ hash: String) async -> CommitInfo? {
        // Same fields as `history` (incl. `%ae`) so the result equals the History row it selects.
        let out = try? await git.run(["log", "-1", hash, "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1f%ae%x1e", "--date=short"], in: url)
        return LogParser.parse(out ?? "").first
    }

    /// Full header detail (message, author/committer, parents) for `CommitDiffView` — one `git
    /// show -s` call, parsed by `CommitDetailParser`.
    public func commitDetail(_ hash: String) async -> CommitDetail? {
        let format = "%H%x1f%s%x1f%b%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%P%x1f%p%x1e"
        let out = try? await git.run(["show", "-s", "--format=\(format)", "--date=iso-strict", hash], in: url)
        return CommitDetailParser.parse(out ?? "")
    }

    /// `parent`, when given (1-based, only meaningful for a merge commit), diffs `hash` against
    /// that specific parent (`git diff <hash>^<parent> <hash>`) — the merge-commit parent picker
    /// in `CommitDiffView`. `nil` keeps the existing default: first-parent diff via `git show`.
    public func commitDiff(_ hash: String, parent: Int? = nil) async -> [FileDiff] {
        let out: String?
        if let parent {
            out = try? await git.run(["diff", "--no-color", "\(hash)^\(parent)", hash], in: url)
        } else {
            out = try? await git.run(["show", "--format=", "--no-color", "--first-parent", "-m", hash], in: url)
        }
        return DiffParser.parse(out ?? "")
    }

    /// Hashes reachable from `branch` but not from `HEAD` (`git log HEAD..<branch>`) — exactly the
    /// commits cherry-pick operates on, per the plan: "commits on a non-current branch that are not
    /// reachable from HEAD". One `git log` call for the whole branch, so `HistoryView` can call this
    /// once per branch selection rather than once per row.
    public func commitsNotReachableFromHead(_ branch: String) async -> Set<String> {
        let out = (try? await git.run(["log", "HEAD..\(branch)", "--pretty=%H"], in: url)) ?? ""
        return Set(out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// Single-commit version of `commitsNotReachableFromHead`, for call sites (⌘K) that only need
    /// to check one commit rather than a whole branch's worth up front.
    public func isAncestorOfHead(_ hash: String) async -> Bool {
        do {
            _ = try await git.run(["merge-base", "--is-ancestor", hash, "HEAD"], in: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - File history & restore

    /// `git log --follow --name-status` for `path`, paged like `history(limit:skip:)`. `--follow`
    /// only works with a single starting path (git's own limitation, not this app's), so unlike
    /// `history` this takes no `filterArgs`/branch — it always follows `path` from `HEAD`. Parsed by
    /// `FileHistoryParser`, which pairs each commit's own `--name-status` line back onto it so a
    /// rename's older entries carry the file's old name.
    public func fileHistory(path: String, limit: Int = 200, skip: Int = 0) async -> [FileHistoryEntry] {
        var args = ["log", "--follow", "--name-status", "-n", "\(limit)"]
        if skip > 0 { args += ["--skip", "\(skip)"] }
        args += ["--pretty=format:%x1e%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1f%ae", "--date=short", "--", path]
        let out = try? await git.run(args, in: url)
        return FileHistoryParser.parse(out ?? "")
    }

    /// Per-file `A`/`M`/`D`/`R` status for a commit — same two branches as `commitDiff` (plain vs.
    /// against a specific merge parent) so the two stay consistent for the same `hash`/`parent`
    /// pair. Used to decide whether "Restore Version Before This Commit" makes sense for a given
    /// file in `CommitDiffView`'s file list (it doesn't when this commit *added* the file).
    public func commitFileStatuses(_ hash: String, parent: Int? = nil) async -> [String: FileHistoryChangeKind] {
        let out: String?
        if let parent {
            out = try? await git.run(["diff", "--name-status", "\(hash)^\(parent)", hash], in: url)
        } else {
            out = try? await git.run(["show", "--format=", "--name-status", "--first-parent", "-m", hash], in: url)
        }
        return NameStatusParser.parse(out ?? "")
    }

    /// `git cat-file -e <commit>:<path>`: whether `path` exists in the tree at `commit`. Used to
    /// gate "Restore Version Before This Commit" before it ever runs `restoreFile` — verified
    /// against real git that `<commit>` being an invalid ref (e.g. `<root-commit>^`, which has no
    /// parent) fails the same way a missing path does, so one check covers both "root commit" and
    /// "file didn't exist yet".
    public func fileExists(_ path: String, at commit: String) async -> Bool {
        (try? await git.run(["cat-file", "-e", "\(commit):\(path)"], in: url)) != nil
    }

    /// `git restore --source=<commit> --worktree -- <path>` (`commit` may be `<hash>^`); index untouched.
    /// Refuses via `lastError` when `path` is absent at `commit`: git would exit 0 and silently
    /// *delete* the working-tree file (verified, git 2.50.1). Callers check `fileExists(_:at:)`
    /// before offering "restore before" so the UI can explain why it's unavailable.
    @discardableResult
    public func restoreFile(_ path: String, from commit: String) async -> Bool {
        if !(await fileExists(path, at: commit)) {
            lastError = GitError(args: ["restore", "--source=\(commit)", "--", path], exitCode: -1,
                                 stderr: "\(path) does not exist at \(String(commit.prefix(7))); restoring would delete it.")
            return false
        }
        return await perform(["restore", "--source=\(commit)", "--worktree", "--", path], literalPathspecs: true)
    }

    // MARK: - Blame

    /// `git blame --porcelain -- <path>`, run against the working-tree file (uncommitted lines
    /// come back with the all-zero hash — see `BlameLine.isUncommitted`). Parsing runs off the
    /// main actor (`Task.detached`): a 20k-line file's porcelain output is a lot of string work to
    /// do synchronously on the actor that also drives the UI. Capped by `BlameCap` so a very large
    /// file still renders something instead of trying to lay out an unbounded row count.
    public func blame(path: String) async -> BlameResult? {
        guard let out = try? await git.run(["blame", "--porcelain", "--", path], in: url) else { return nil }
        let lines = await Task.detached(priority: .userInitiated) { BlamePorcelainParser.parse(out) }.value
        return BlameCap.apply(lines)
    }

    // MARK: - Compare (T4)

    /// The Compare tab's default base: the remote's default branch (`git symbolic-ref
    /// refs/remotes/origin/HEAD`, which prints `refs/remotes/origin/<branch>` when `origin/HEAD`
    /// is set and fails with exit 128 and empty output when it isn't — verified against real git),
    /// else local `main`, else local `master`, else `nil` (the UI then asks the user to pick one).
    /// `CompareBase.resolve` does the actual decision, pure and unit-tested; this just gathers its
    /// two inputs from git.
    public func defaultBaseBranch() async -> String? {
        let ref = try? await git.run(["symbolic-ref", "refs/remotes/origin/HEAD"], in: url, allowedExitCodes: [0, 128])
        let localBranches = branches.filter { !$0.isRemote }.map(\.name)
        return CompareBase.resolve(originHEADRef: ref, localBranches: localBranches)
    }

    /// The base the user sees in Compare: their persisted choice, else `defaultBaseBranch()`.
    /// Delete Merged Branches measures "merged" against this too.
    public func baseBranch() async -> String? {
        if let restoredCompareBase { return restoredCompareBase }
        return await defaultBaseBranch()
    }

    /// Ahead/behind counts for `base`/`head` — `git rev-list --left-right --count base...head`.
    public func compareCounts(base: String, head: String) async -> CompareCounts {
        let out = (try? await git.run(["rev-list", "--left-right", "--count", "\(base)...\(head)"], in: url)) ?? ""
        return CompareCounts.parse(out)
    }

    /// Commits on `head` not on `base` (`git log base..head`, two-dot) — the same format/parser as
    /// `history`, so `CompareView`'s commit list looks and behaves like `HistoryView`'s.
    public func compareCommits(base: String, head: String) async -> [CommitInfo] {
        let out = try? await git.run(["log", "\(base)..\(head)", "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1f%ae%x1e", "--date=short"], in: url)
        return LogParser.parse(out ?? "")
    }

    /// The combined change for the Compare tab: `git diff base...head` (three dots — the range
    /// operator, not `base..head`'s two). `base...head` diffs `head` against the *merge base* of
    /// `base` and `head`, i.e. exactly the changes introduced on `head` since it diverged — the
    /// same commits `compareCommits` lists. A plain two-dot `git diff base..head` (which for `diff`
    /// is actually identical to no-dot `git diff base head`) instead diffs the two branch tips
    /// directly, so it would also include whatever `base` picked up on its own since the branches
    /// split — changes this branch never made and can't be reviewed for. Three dots is "what did
    /// head do", not "how do the two tips currently differ".
    public func compareDiff(base: String, head: String) async -> [FileDiff] {
        let out = try? await git.run(["diff", "--no-color", "\(base)...\(head)"], in: url)
        return DiffParser.parse(out ?? "")
    }
}
