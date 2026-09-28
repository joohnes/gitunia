import Foundation

extension RepositoryStore {
    // MARK: Rebase onto another branch

    public func rebasePlan(onto: String) async -> RebasePlan {
        func hashes(_ range: String) async -> Set<Substring> {
            Set(((try? await git.run(["rev-list", range], in: url)) ?? "").split(separator: "\n"))
        }
        let replay = await hashes("\(onto)..HEAD")
        let pushed = hasUpstream ? replay.intersection(await hashes("\(onto)..@{upstream}")).count : 0
        let dirty = Set(repo.changes.filter { $0.status != .untracked }.map(\.path)).count
        return RebasePlan(branch: repo.branch ?? "HEAD", onto: onto, replayCount: replay.count,
                          pushedCount: pushed, newOnOnto: await revCount(["HEAD..\(onto)"]), dirtyCount: dirty)
    }

    /// `git rebase [--autostash] <onto>`. `--autostash` (git's own stash-first) rather than a
    /// separate `stash push`: git re-applies the changes itself when the rebase finishes — also
    /// after a `--continue`/`--abort` from the operation banner — and holds them in
    /// `rebase-merge/autostash`, not the stash list, while the rebase is stopped.
    @discardableResult
    public func rebase(onto: String, autostash: Bool = false) async -> RebaseOutcome {
        var args = ["-c", "core.editor=true", "rebase"]
        if autostash { args.append("--autostash") }
        args.append(onto)
        switch await runCapturing(args) {
        case .success(let out):
            return .rebased(autostashConflicted: out.contains("Applying autostash resulted in conflicts"))
        case .failure(let e):
            if operation == .rebase { return .stoppedOnConflicts }
            lastError = e
            return .failed
        }
    }

    // MARK: Stash, fuller

    public func stashItems() async -> [StashItem] {
        let out = (try? await git.run(["stash", "list", "--format=\(StashItemParser.format)"], in: url)) ?? ""
        return StashItemParser.parse(out)
    }

    /// `git stash show -p --include-untracked <hash>`. Verified: untracked files stashed with
    /// `-u` appear as `new file` diffs; on an entry without untracked files the flag is harmless.
    /// By hash, so it's immune to index shifts. `GitRunner` already adds `--no-ext-diff`/
    /// `--no-textconv` to every `stash show` call (C1), so this doesn't repeat them.
    public func stashDiff(_ item: StashItem) async -> [FileDiff] {
        let out = (try? await git.run(["stash", "show", "-p", "--include-untracked", "--no-color", item.hash], in: url)) ?? ""
        return DiffParser.parse(out)
    }

    /// `git stash apply` (keeps the entry) or `git stash pop`.
    @discardableResult
    public func stashApply(_ item: StashItem, pop: Bool) async -> StashApplyOutcome {
        guard let ref = await verifiedStashRef(item, verb: pop ? "pop" : "apply") else { return .failed }
        // Git refuses outright ("needs merge") with conflicts already present, so only *new*
        // conflicts mean this apply stopped on them.
        let conflictsBefore = conflictedChanges.count
        let result = await runCapturing(["stash", pop ? "pop" : "apply", ref])
        await refreshStashCount()
        switch result {
        case .success: return .applied
        case .failure(let e):
            let conflicted = conflictedChanges.count
            if conflicted > conflictsBefore { return .conflicts(conflicted) }
            lastError = e
            return .failed
        }
    }

    @discardableResult
    public func stashDrop(_ item: StashItem) async -> Bool {
        guard let ref = await verifiedStashRef(item, verb: "drop") else { return false }
        let result = await runCapturing(["stash", "drop", ref])
        await refreshStashCount()
        if case .failure(let e) = result { lastError = e; return false }
        return true
    }

    /// `git stash push -u [-m] -- <paths>`. `-u` is required, not optional: without it
    /// a selected untracked file fails the whole command ("pathspec … did not match any file(s)
    /// known to git"); with it, only *selected* untracked files are taken (verified). Passes
    /// `literalPathspecs: true` (C2/L9) so a name like `a[1].txt` is taken literally rather than as
    /// a glob that would also match `a1.txt` — set only on calls that actually pass a pathspec,
    /// since `GIT_LITERAL_PATHSPECS=1` is verified to break a *pathspec-less* `stash push -u` (see
    /// `GitRunner`).
    @discardableResult
    public func stashFiles(_ paths: [String], message: String? = nil) async -> StashSelectedOutcome {
        let selected = Set(paths)
        let otherStaged = Set(stagedChanges.map(\.path)).subtracting(selected)
        if !otherStaged.isEmpty { return .otherFilesStaged(otherStaged.sorted()) }
        var args = ["stash", "push", "-u"]
        if let message, !message.isEmpty { args += ["-m", message] }
        args += ["--"] + paths
        let result = await runCapturing(args, literalPathspecs: true)
        await refreshStashCount()
        switch result {
        case .success(let out): return out.contains("No local changes to save") ? .nothingToStash : .stashed
        case .failure(let e): lastError = e; return .failed
        }
    }

    // MARK: Gitunia-labelled stashes

    public func stashLabel(for branch: String) -> String {
        StashLabel.make(repo: repo.name, branch: branch)
    }

    /// `stash push -u` (tracked + untracked) under `stashLabel` for the current branch. False
    /// when there was nothing to stash or it failed (see `stash(message:)`).
    @discardableResult
    public func autoStash() async -> Bool {
        await stash(message: stashLabel(for: repo.branch ?? "HEAD"))
    }

    /// Stashes Gitunia made, newest first (git's list order).
    public func gituniaStashes() async -> [StashItem] {
        await stashItems().filter { $0.gituniaLabel != nil }
    }

    /// Files in a stash, untracked included. One process per call — callers cap how many they ask.
    public func stashFileCount(_ item: StashItem) async -> Int? {
        guard let out = try? await git.run(["stash", "show", "--name-only", "--include-untracked", item.hash], in: url) else { return nil }
        return out.split(separator: "\n").count
    }

    /// `stash@{n}` if it still names `item.hash`; otherwise sets `lastError` and returns nil.
    private func verifiedStashRef(_ item: StashItem, verb: String) async -> String? {
        let current = (try? await git.run(["rev-parse", "--verify", "-q", item.ref], in: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == item.hash else {
            lastError = GitError(args: ["stash", verb, item.ref], exitCode: -1,
                                 stderr: "The stash list changed since it was shown — nothing was done. Reopen it and try again.")
            await refreshStashCount()
            return nil
        }
        return item.ref
    }

    /// Runs git, refreshes status, and hands back stdout+stderr or the error — *without* touching
    /// `lastError`, so a caller can classify "stopped on conflicts" before `ContentView`'s generic
    /// error watcher ever sees a raw failure.
    private func runCapturing(_ args: [String], literalPathspecs: Bool = false) async -> Result<String, GitError> {
        await exec(args, literalPathspecs: literalPathspecs, recordError: false) { $0.map { $0.stdout + $0.stderr } }
    }
}
