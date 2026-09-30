import Foundation

extension RepositoryStore {
    // MARK: - Status

    private var eventSnapshot: RepoEvent.Snapshot {
        RepoEvent.Snapshot(headOID: repo.headOID, branches: Set(branches.filter { !$0.isRemote }.map(\.name)), operation: operation)
    }

    /// Fills `FileChange.size` with one stat per untracked/added/modified path, off the main actor.
    /// ponytail: skips sizing entirely past 500 changes — a mass agent rewrite shouldn't cost
    /// thousands of stats per tick; size those lazily per visible row if that ever matters.
    nonisolated static func withSizes(_ changes: [FileChange], in root: URL) async -> [FileChange] {
        guard changes.count <= 500 else { return changes }
        return await Task.detached(priority: .utility) {
            changes.map { change in
                guard [.untracked, .added, .modified].contains(change.status) else { return change }
                var sized = change
                let attrs = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(change.path).path)
                sized.size = (attrs?[.size] as? NSNumber)?.intValue
                return sized
            }
        }.value
    }

    /// Observation fires on every write, equal value or not — so a status tick that changed nothing
    /// would still re-render every view reading that property. Writes only a real difference.
    func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<RepositoryStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    public func refreshStatus() async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            update(\.repo.isAvailable, false)
            return
        }
        update(\.repo.isAvailable, true)
        statusGeneration += 1
        let gen = statusGeneration
        do {
            // These three calls are independent of one another — run them concurrently instead of
            // one after another (M3). `async let` starts each child task immediately; results are
            // only applied to `repo`/actor state below, sequentially, once every call has returned.
            // `GitRunner` passes `--no-optional-locks` (H1) on every call, which keeps `status` from
            // taking git's index lock, so a background refresh never rewrites `.git/index`'s mtime
            // and re-triggers itself via FSEvents. `--branch` also reports the upstream.
            async let statusOut = git.run(["status", "--porcelain=v2", "-uall", "--branch"], in: url)
            async let refsOut: String = (try? await git.run(["for-each-ref", "--format=%(refname)%09%(HEAD)", "refs/heads", "refs/remotes"], in: url)) ?? ""
            // One `git log` answers both questions: the first record is HEAD's subject, and a
            // second record existing means HEAD has a parent — one process fewer than a separate
            // `rev-parse HEAD~1`. The `%x1f` prefix makes every record a non-empty line even for a
            // commit with an empty subject, so counting lines stays honest. Author name/email ride
            // along for `AgentProfile` (sidebar tooltip).
            async let logOut: String = (try? await git.run(["log", "-2", "--pretty=%x1f%s%x1f%an%x1f%ae"], in: url)) ?? ""

            let statusText = try await statusOut
            // Off the main actor: thousands of changed files is tens of ms of line parsing.
            let (status, upstream) = await Task.detached(priority: .userInitiated) {
                (StatusParser.parse(statusText), StatusParser.upstream(in: statusText))
            }.value
            let refsResult = await refsOut
            let logRecords = (await logOut).split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.dropFirst().split(separator: "\u{1f}", omittingEmptySubsequences: false) }
            let sizedChanges = await Self.withSizes(status.changes, in: url)
            guard gen == statusGeneration else { return }
            // The first load has nothing to compare against — every branch would read as "added".
            let beforeEvents = hasLoadedStatus ? eventSnapshot : nil
            // Built on a copy and assigned once, only if it differs (see `update`).
            var next = repo
            next.branch = status.branch
            next.headOID = status.headOID
            next.ahead = status.ahead
            next.behind = status.behind
            next.changes = sizedChanges
            let head = logRecords.first
            next.lastCommitSummary = head?.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            next.lastCommitAuthor = head.flatMap { $0.count > 1 ? String($0[1]) : nil }
            next.lastCommitEmail = head.flatMap { $0.count > 2 ? String($0[2]) : nil }
            let oldChanges = repo.changes
            update(\.repo, next)
            let newFingerprint = repo.fingerprint
            // The fingerprint ignores content; sizes also catch a re-edit of an already-modified file.
            // ponytail: a same-size re-edit still slips through — add mtimes to `withSizes` if that bites.
            if newFingerprint != fingerprint || sizedChanges != oldChanges { workingTreeVersion += 1 }
            if newFingerprint != fingerprint {
                if fingerprint != nil { lastActivity = Date() }
                fingerprint = newFingerprint
                // Never viewed: today's state is the baseline (in memory only — no prefs write per repo).
                if lastViewedFingerprint == nil { lastViewedFingerprint = newFingerprint }
                onFingerprintChange?(self)
            }
            update(\.branches, BranchParser.parse(refsResult))
            update(\.hasUpstream, upstream != nil)
            let upstreamParts = (upstream ?? "").split(separator: "/", maxSplits: 1).map(String.init)
            update(\.upstreamRemote, upstreamParts.first)
            update(\.upstreamBranch, upstreamParts.count == 2 ? upstreamParts[1] : nil)
            update(\.hasParentCommit, logRecords.count > 1)
            refreshOperationState()
            hasLoadedStatus = true
            if let beforeEvents, let onEvents {
                let events = RepoEvent.diff(old: beforeEvents, new: eventSnapshot)
                if !events.isEmpty { onEvents(events) }
            }
            await refreshAttributeRules()
            guard gen == statusGeneration else { return }
            await refreshReviewState()
            guard gen == statusGeneration else { return }
            await refreshBaseAheadCountIfNeeded()
            guard gen == statusGeneration else { return }
            await refreshSubmodules()
            // One extra `git bisect log` only while bisecting (or once more to clear it after).
            if operation == .bisect || bisect != nil { await refreshBisect() }
        } catch is CancellationError {
            return
        } catch let e as GitError {
            guard gen == statusGeneration else { return }
            lastError = e
        } catch {
            guard gen == statusGeneration else { return }
            lastError = GitError(args: ["status"], exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// The actual `.git` directory: usually `<repo>/.git`, but in a worktree or submodule `.git` is a
    /// *file* containing `gitdir: <path>` pointing elsewhere. Resolved once found — it never moves
    /// during a session — and retried while the folder isn't a repo yet. Public so `WorkspaceStore`
    /// can map an FSEvents path under `<main>/.git/worktrees/<name>/...` back to this linked worktree.
    public func gitDirURL() -> URL? {
        if let resolvedGitDir { return resolvedGitDir }
        resolvedGitDir = Self.resolveGitDir(url)
        return resolvedGitDir
    }

    /// Internal (not private): `RepositoryStore.gitDir(forWorktree:)` reuses this same resolution
    /// for an arbitrary worktree path, not just `self.url` (B9).
    static func resolveGitDir(_ url: URL) -> URL? {
        let dotGit = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let firstLine = contents.split(separator: "\n").first,
              firstLine.hasPrefix("gitdir: ")
        else { return nil }
        let path = firstLine.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
    }

    /// Verified against real git output in temp repos (see `OperationStateTests`): a cherry-pick
    /// conflict writes `CHERRY_PICK_HEAD` only (no `MERGE_HEAD`), a revert conflict writes
    /// `REVERT_HEAD` only, and a rebase writes `rebase-merge`/`rebase-apply` — none of the four
    /// files/directories ever coexist, so the checks below don't need to be mutually exclusive in
    /// their ordering, just exhaustive.
    private func refreshOperationState() {
        guard let gitDir = gitDirURL() else {
            update(\.operation, nil)
            return
        }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        let found: GitOperation? =
            if exists("rebase-merge") || exists("rebase-apply") { .rebase }
            else if exists("MERGE_HEAD") { .merge }
            else if exists("CHERRY_PICK_HEAD") { .cherryPick }
            else if exists("REVERT_HEAD") { .revert }
            else if exists("BISECT_LOG") { .bisect }
            else { nil }
        update(\.operation, found)
    }

    // MARK: - Review point

    /// Everything up to the current HEAD counts as reviewed from now on.
    public func markReviewed() {
        guard let head = repo.headOID else { return }
        reviewedHead = head
        unreviewedCount = 0
        reviewPointMissing = false
        reviewStateKey = "\(head)-\(head)"
        onMarkReviewed?(self)
    }

    /// One `rev-list --left-right --count <reviewed>...HEAD` answers both "how many unreviewed" (right)
    /// and "is the review point still an ancestor" (left == 0); fails outright if it was gc'd.
    /// Only runs when `reviewedHead` or HEAD moved since last time.
    private func refreshReviewState() async {
        guard let reviewed = reviewedHead, let head = repo.headOID else {
            update(\.unreviewedCount, nil); update(\.reviewPointMissing, false); reviewStateKey = nil
            return
        }
        let key = "\(reviewed)-\(head)"
        guard key != reviewStateKey else { return }
        reviewStateKey = key
        if reviewed == head { unreviewedCount = 0; reviewPointMissing = false; return }
        let out = (try? await git.run(["rev-list", "--left-right", "--count", "\(reviewed)...HEAD"], in: url)) ?? ""
        let counts = out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        if counts.count == 2, counts[0] == 0 {
            unreviewedCount = counts[1]; reviewPointMissing = false
        } else {
            unreviewedCount = nil; reviewPointMissing = true
        }
    }

    /// Recomputes `baseAheadCount` (the sidebar's "↑N vs main" hint) only when the current branch
    /// name has changed since the last time this ran — not on every `refreshStatus()` call:
    /// `defaultBaseBranch()` plus `compareCounts` are two more process spawns (~9ms each), and a
    /// checkout is rare compared with ordinary file edits. ponytail: this misses the case where
    /// only the *base* branch's tip moves (e.g. `main` gets fetched) while the current branch stays
    /// the same — the hint goes stale until the next checkout or app relaunch; add a refs-changed
    /// check here if that staleness turns out to matter in practice.
    private func refreshBaseAheadCountIfNeeded() async {
        guard let branch = repo.branch else {
            update(\.baseAheadCount, nil)
            update(\.baseAheadBranch, nil)
            lastBaseAheadCheckBranch = nil
            return
        }
        guard branch != lastBaseAheadCheckBranch else { return }
        lastBaseAheadCheckBranch = branch
        guard let base = await baseBranch(), base != branch else {
            baseAheadCount = nil
            baseAheadBranch = nil
            return
        }
        baseAheadCount = await compareCounts(base: base, head: branch).ahead
        baseAheadBranch = base
    }
}
