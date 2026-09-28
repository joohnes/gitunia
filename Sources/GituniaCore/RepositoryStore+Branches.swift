import Foundation

extension RepositoryStore {
    // MARK: - Remote & branches

    @discardableResult
    public func fetch() async -> RemoteResult {
        let remote = await defaultFetchRemote()
        return await performRemote(.fetch, ["fetch", "--prune"] + (remote.map { ["--", $0] } ?? []))
    }

    /// The background auto-fetch tick: skips a repo whose own `.git/config` names a command git
    /// would run to fetch (ssh command, credential helper, proxy, upload-pack) — anything that can
    /// write the repo, an agent included, can put one there, and a timer must not run it. A manual
    /// fetch still does: that's the user's click.
    func autoFetch() async -> RemoteResult {
        let keys = #"^(core\.(sshcommand|gitproxy)|credential\..*helper|remote\..*\.uploadpack|protocol\..*allow)$"#
        let local = (try? await git.run(["config", "--local", "--name-only", "--get-regexp", keys], in: url,
                                        allowedExitCodes: [0, 1])) ?? ""
        let found = local.split(separator: "\n").map(String.init)
        guard found.isEmpty else {
            return RemoteResult(kind: .fetch, succeeded: false,
                                summary: "Auto-fetch skipped: this repository's own config sets \(found.joined(separator: ", ")) — fetch manually")
        }
        return await fetch()
    }

    @discardableResult
    public func pull() async -> RemoteResult {
        await performRemote(.pull, ["pull", "--ff-only"])
    }

    /// Rebases the local commits on top of upstream — the "Rebase my commits on top" choice offered
    /// when `Preflight.isDiverged` is true. `performRemote` already runs `refreshStatus()` afterward,
    /// which is what picks up `rebaseInProgress` if this stops on a conflict.
    @discardableResult
    public func pullRebase() async -> RemoteResult {
        await performRemote(.pull, ["pull", "--rebase"])
    }

    /// Merges upstream into the local branch — the "Merge" choice for the same diverged case.
    /// `--no-ff` forces an actual merge commit rather than relying on `pull.ff`/`merge.ff`, which a
    /// user's global git config could set to fast-forward-when-possible (moot for a genuinely
    /// diverged branch, since a fast-forward isn't possible there, but explicit beats implicit for
    /// an action the UI describes as "creates a merge commit").
    @discardableResult
    public func pullMerge() async -> RemoteResult {
        await performRemote(.pull, ["pull", "--no-rebase", "--no-ff"])
    }

    /// Pushes the current branch. Without an upstream — or when plain `git push` refuses because
    /// the cached `hasUpstream` was stale or the upstream has a different name — pushes with
    /// `--set-upstream <remote> <branch>` to the default remote, else "origin", else the first one
    /// (`RemoteSelection.pushRemote`).
    @discardableResult
    public func push() async -> RemoteResult {
        if hasUpstream {
            let result = await performRemote(.push, ["push"])
            guard result.failureKind == .noUpstream else { return result }
        }
        return await pushSettingUpstream()
    }

    private func pushSettingUpstream() async -> RemoteResult {
        beginBusy()
        guard let remote = RemoteSelection.pushRemote(from: await remoteList(), preferred: defaultRemote) else {
            let error = GitError(args: ["push"], exitCode: -1,
                                 stderr: "\(RemoteOutputParser.noRemoteMessage) Add one with `git remote add origin <url>`.")
            lastError = error
            endBusy()
            return RemoteResult(kind: .push, succeeded: false, summary: "No remote configured", error: error)
        }
        // Live, not `repo.branch` — the cached name is exactly what can be stale here.
        let branch = ((try? await git.run(["symbolic-ref", "--short", "HEAD"], in: url)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        endBusy()
        return await performRemote(.push, ["push", "--set-upstream", remote, branch.isEmpty ? "HEAD" : branch], remote: remote)
    }

    /// `git push --force-with-lease` to the existing upstream. Refuses outright without an
    /// upstream — a first push is never forced, there's nothing on the remote yet to overwrite —
    /// rather than falling back to `push -u` like `push()` does. `--force-with-lease` (not a bare
    /// `--force`) refuses if the remote moved since this repo's last fetch, surfacing as
    /// `RemoteResult.failureKind == .leaseStale`; see `RemoteOutputParser.pushFailureKind`.
    ///
    /// `branch` (default: the current one) is pushed with an explicit single refspec
    /// `refs/heads/<branch>:<its upstream merge ref>` — never a bare `git push --force-with-lease`,
    /// which under `push.default=matching` force-updates *every* matching branch, and which pushes
    /// whatever HEAD is at run time rather than the branch the user confirmed.
    @discardableResult
    public func forcePush(branch: String? = nil) async -> RemoteResult {
        let name = branch ?? repo.branch ?? ""
        func config(_ key: String) async -> String {
            ((try? await git.run(["config", "--get", "branch.\(name).\(key)"], in: url)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let remote = await config("remote")
        let merge = await config("merge")
        guard !name.isEmpty, !remote.isEmpty, remote != ".", merge.hasPrefix("refs/heads/") else {
            let error = GitError(args: ["push", "--force-with-lease"], exitCode: -1,
                                  stderr: "No upstream branch configured — a first push is never forced.")
            lastError = error
            return RemoteResult(kind: .push, succeeded: false, summary: "No upstream branch configured", error: error)
        }
        return await performRemote(.push, ["push", "--force-with-lease", remote, "refs/heads/\(name):\(merge)"], remote: remote)
    }

    /// Checks out a local branch, or creates a tracking branch from a remote one.
    /// If a local branch with the derived name already exists, switches to it instead of re-tracking.
    public func checkout(_ branch: BranchInfo) async -> Bool {
        if branch.isRemote {
            let localName = branch.name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? branch.name
            if branches.contains(where: { !$0.isRemote && $0.name == localName }) {
                return await perform(["checkout", "-q", localName])
            }
            return await perform(["checkout", "-q", "--track", branch.name])
        }
        return await perform(["checkout", "-q", branch.name])
    }

    public func createBranch(_ name: String) async -> Bool {
        await perform(["checkout", "-q", "-b", name])
    }

    // MARK: - Branch verbs (merge / rename / delete)

    /// `git merge --no-edit <branch>` into the current branch. A conflict leaves `MERGE_HEAD`
    /// behind (picked up by the following `refreshStatus()` as `operation == .merge`, same as every
    /// other conflict-producing action in this file) rather than throwing — the caller reads
    /// `MergeResult.succeeded == false` and `operation == .merge` to tell a real failure apart from
    /// "stopped on conflicts".
    @discardableResult
    public func mergeBranch(_ branch: String) async -> MergeResult {
        await exec(["merge", "--no-edit", branch]) { result in
            switch result {
            case .success(let out): MergeResult(succeeded: true, wasFastForward: (out.stdout + out.stderr).contains("Fast-forward"))
            case .failure(let e): MergeResult(succeeded: false, wasFastForward: false, error: e)
            }
        }
    }

    /// `git branch -m <branch> <newName>`. Validates `newName` with `git check-ref-format --branch`
    /// and rejects an existing local branch name *before* calling git, so the caller gets a specific
    /// reason instead of a raw git error. Renaming never touches the remote — if `branch` has an
    /// upstream, the caller is told so it can say the remote branch keeps its old name.
    @discardableResult
    public func renameBranch(_ branch: String, to newName: String) async -> RenameOutcome {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await branchNameProblem(trimmed) { return .invalidName(problem) }
        guard trimmed != branch else { return .invalidName("That's already this branch's name") }
        if branches.contains(where: { !$0.isRemote && $0.name == trimmed }) {
            return .duplicateName
        }
        let upstream = (try? await git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(branch)@{upstream}"],
                                            in: url, allowedExitCodes: [0, 128])) ?? ""
        let hadUpstream = !upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return await exec(["branch", "-m", branch, trimmed], refreshOnLaunchFailure: false) { result in
            result.failure.map { .failed($0) } ?? .succeeded(keptOldRemoteName: hadUpstream)
        }
    }

    /// Why `name` (already trimmed) can't be a branch name — empty, or refused by
    /// `git check-ref-format --branch` — or nil when it can.
    func branchNameProblem(_ name: String) async -> String? {
        if name.isEmpty { return "Branch name can't be empty" }
        if (try? await git.run(["check-ref-format", "--branch", name], in: url)) == nil { return "\"\(name)\" isn't a valid branch name" }
        return nil
    }

    /// `git branch -d` (or `-D` when `force`). On a real "not fully merged" refusal, the captured
    /// stderr is classified so the caller can offer the force-delete confirmation without
    /// re-parsing git's wording itself — see `BranchOpsTests` for the exact real message this
    /// matches against.
    @discardableResult
    public func deleteBranch(_ branch: String, force: Bool = false) async -> BranchDeleteResult {
        // `lastError` is set only after the refresh (the last suspension point): a caller that handles
        // "not fully merged" itself (the force-delete dialog) clears it on return, before any view
        // update can run ContentView's generic `lastError` toast watcher.
        await exec(["branch", force ? "-D" : "-d", branch], recordError: false, refreshOnLaunchFailure: false) { result in
            guard let e = result.failure else { return BranchDeleteResult(succeeded: true, notFullyMerged: false) }
            lastError = e
            return BranchDeleteResult(succeeded: false, notFullyMerged: e.stderr.localizedCaseInsensitiveContains("not fully merged"), error: e)
        }
    }

    /// `git push <remote> --delete <branch>` — removes the branch from the remote. Affects every
    /// clone tracking it, which is why the UI confirms this by name (remote + branch) before calling
    /// it, same destructive-confirmation shape as `forcePush`.
    @discardableResult
    public func deleteRemoteBranch(_ branch: String, remote: String) async -> Bool {
        await perform(["push", remote, "--delete", branch])
    }

    /// Like `perform`, but captures stdout+stderr to build a `RemoteResult` with a parsed summary.
    /// `isBusy` (via `exec`'s `beginBusy`/`endBusy`) only spans the actual `git fetch`/`pull`/`push` —
    /// the activity snapshot/diff and the `gh pr list` enrichment run afterward, in a detached `Task`,
    /// so a fetch's spinner doesn't stay up through `gh`'s up-to-20s timeout. The ref snapshot inside
    /// that `Task` is still taken from the *post-fetch* refs and before the slow `git log`/`gh` calls:
    /// `recordRemoteActivity` already reads the local refs (`readRemoteRefs`, a fast `for-each-ref`)
    /// as its first step, so kicking off the whole call from here preserves that ordering.
    func performRemote(_ kind: RemoteKind, _ args: [String], remote: String = "origin") async -> RemoteResult {
        let result = await exec(args) { result -> RemoteResult in
            guard case .success(let out) = result else {
                return RemoteResult(kind: kind, succeeded: false, summary: "\(kind.rawValue.capitalized) failed", error: result.failure)
            }
            let summary = RemoteOutputParser.summary(for: kind, stdout: out.stdout, stderr: out.stderr, remote: remote)
            return RemoteResult(kind: kind, succeeded: true, summary: summary)
        }
        guard result.succeeded else { return result }
        if kind == .push, pullRequestsSupported { Task { await refreshPullRequest() } }
        if kind == .fetch || kind == .pull, tracksRemoteActivity {
            Task {
                let events = await recordRemoteActivity(after: true)
                if !events.isEmpty { onRemoteActivity?(events) }
            }
        }
        return result
    }
}
