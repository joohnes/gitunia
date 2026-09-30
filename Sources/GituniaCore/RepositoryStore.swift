import Foundation
import Observation

@MainActor
@Observable
public final class RepositoryStore: Identifiable {
    public internal(set) var repo: Repository {
        // Partitioned once per real change of the list, not on every read: views read these
        // several times per `body`, and with thousands of changes each read was a full filter.
        didSet { if repo.changes != oldValue.changes { partition = ChangePartition(repo.changes) } }
    }
    private var partition = ChangePartition([])
    public var lastError: GitError?
    public private(set) var isBusy = false
    /// Backing counter for `isBusy` — overlapping operations (e.g. auto-fetch racing a user click)
    /// must not let the first to finish clear `isBusy` while the other is still running. Mutate only
    /// through `beginBusy()`/`endBusy()`.
    private var busyCount = 0 { didSet { isBusy = busyCount > 0 } }

    /// Pair with a `defer { endBusy() }` around any git/filesystem work so `isBusy` reflects however
    /// many such operations are in flight, not just the last one to start.
    func beginBusy() { busyCount += 1 }
    func endBusy() { busyCount -= 1 }
    public internal(set) var branches: [BranchInfo] = []
    public internal(set) var hasUpstream = false
    /// The remote name (e.g. `"origin"`) the current branch tracks, parsed from `@{upstream}`'s
    /// `<remote>/<branch>` form — `nil` when there's no upstream. Exists so the force-push
    /// confirmation dialog can name the actual remote instead of assuming "origin" (the
    /// simplification `push()`'s summary already makes for its own display string).
    public internal(set) var upstreamRemote: String?
    /// The branch part of `@{upstream}` (e.g. `"old"` from `"origin/old"`) — `nil` without one.
    public internal(set) var upstreamBranch: String?
    /// `false` when the upstream's branch name differs from the local one — typically right after
    /// `renameBranch`, since `git branch -m` carries `branch.<name>.merge` along. Plain `git push`
    /// refuses that under `push.default=simple`, and `repo.ahead` counts against the *old* remote
    /// branch, so the push preflight must not treat it as a real upstream ("Nothing to push").
    public var upstreamMatchesBranch: Bool { upstreamBranch == nil || upstreamBranch == repo.branch }
    /// Whether HEAD has a parent commit — `false` for the repository's root commit (or when there
    /// are no commits at all). Refreshed alongside `hasUpstream`; `Preflight` needs it for
    /// `.undoLastCommit` but is a pure function over `Repository` and can't shell out to check
    /// `HEAD~1` itself, so the store resolves it here and passes it in, the same way `hasUpstream`
    /// already is.
    public internal(set) var hasParentCommit = false
    /// Number of stash entries. `refreshStatus()` runs for every repo on every FSEvents tick, so it
    /// never pays for rarely-needed state like this (nor the other lazily loaded properties below):
    /// the view loads it once per repo selection (`ContentView`) and `stash()`/`stashPop()` keep it in sync.
    public private(set) var stashCount = 0
    /// Effective user.name/email and signing config — `nil` until first loaded. Lazily refreshed,
    /// never by `refreshStatus()`: see `RepositoryStore+Identity`.
    public internal(set) var identity: CommitIdentity?
    /// Which of merge/rebase/cherry-pick/revert/bisect (if any) is in progress — detected from
    /// marker files in `.git` with `FileManager` stats, never a git process (see `refreshOperationState`).
    public internal(set) var operation: GitOperation?
    /// Sidebar "↑N vs main" hint (T4 item 4): how many commits the current branch is ahead of the
    /// resolved Compare base — `nil` when there's no base to compare against, or the current
    /// branch *is* the base. See `refreshBaseAheadCountIfNeeded` for why this isn't simply
    /// recomputed on every `refreshStatus()` call.
    public internal(set) var baseAheadCount: Int?
    /// The base name `baseAheadCount` was computed against (e.g. `"master"`) — `RepoRow` needs this
    /// to label the hint, and it's cheaper to remember than to re-resolve on every render.
    public internal(set) var baseAheadBranch: String?
    /// The branch `baseAheadCount` was last computed for — lets `refreshBaseAheadCountIfNeeded`
    /// skip the extra git calls when the branch hasn't actually changed since last time.
    var lastBaseAheadCheckBranch: String?
    /// `git submodule status --recursive`, refreshed only when `.gitmodules` exists — see `RepositoryStore+Submodules`.
    public internal(set) var submodules: [Submodule] = []
    /// Parsed `git bisect log` while `operation == .bisect` — see `RepositoryStore+Bisect`.
    public internal(set) var bisect: BisectState?
    /// Stdout of the last bisect command — the only place git prints "Bisecting: N left".
    @ObservationIgnored var bisectLastOutput = ""
    /// Root `.gitattributes`, re-parsed only when its mtime changes — see `RepositoryStore+LFS`.
    public internal(set) var attributeRules: [AttributeRule] = [] { didSet { lfsMatcher = LFSMatcher(attributeRules) } }
    public private(set) var lfsMatcher = LFSMatcher([])
    var attributesMTime: Date?
    /// Test seam: a directory prepended to `git lfs`'s PATH, pointing it at a fake `git-lfs` instead
    /// of the real PATH. Nil in the app — see `RepositoryStore+LFS`.
    @ObservationIgnored public var lfsPathOverride: String?
    /// Parsed `.gitmodules` and the mtime it was read at — see `refreshSubmodules`.
    @ObservationIgnored var gitmodulesCache: (mtime: Date?, modules: [String: (name: String, url: String?, branch: String?)])?
    /// During a rebase, "ours"/"theirs" are the *opposite* of what they mean during every other
    /// operation (merge, cherry-pick, revert) — see `useOurs`/`useTheirs`.
    public var rebaseInProgress: Bool { operation == .rebase }
    /// Read-once hint for the view layer at the moment a repository is selected — not live state.
    public internal(set) var restoredSelectedPath: String?
    /// Read-once hint for the view layer at the moment a repository is selected — not live state.
    /// `internal(set)` rather than `private(set)`: `WorkspaceStore.setCommitDraft` (C4) updates this
    /// in memory immediately, ahead of its debounced disk write, so switching tabs/repos and back
    /// before the debounce fires still sees the latest typed draft rather than a stale reload.
    public internal(set) var restoredDraft: CommitMessage?
    /// The persisted Compare base for this repository (T4), read once when the repository is
    /// selected/loaded — same "hint, not live state" shape as `restoredSelectedPath`. `CompareView`
    /// falls back to `defaultBaseBranch()` when this is nil.
    public internal(set) var restoredCompareBase: String?

    /// Git tags (`refs/tags`), refreshed by `refreshTags()` in `RepositoryStore+Tags.swift`.
    public internal(set) var gitTags: [GitTag] = []
    /// Last `hooks()` result (`RepositoryStore+Hooks.swift`) — lazy, refreshed on repo selection.
    public internal(set) var gitHooks: [GitHook] = []
    /// Remote used by `fetch()` (no upstream) and a first `push()` — `RepoPrefs.defaultRemote`.
    public private(set) var defaultRemote: String?
    /// `RepoPrefs.secretScanIgnoredPaths` — dropped by `withoutIgnoredSecrets`.
    public private(set) var secretScanIgnoredPaths: Set<String> = []
    /// `git remote` names. Not refreshed by `refreshStatus()` (same cost reasoning as `stashCount`):
    /// loaded on repo selection and after every remote edit — see `RepositoryStore+Remotes`.
    public internal(set) var remoteNames: [String] = []
    /// `repo.fingerprint` as of the last `refreshStatus()` — `nil` until the first one lands.
    public internal(set) var fingerprint: String?
    /// `RepoPrefs.lastViewedFingerprint`; `WorkspaceStore` writes it while this repo is selected.
    public internal(set) var lastViewedFingerprint: String?
    /// Last time `refreshStatus()` saw the fingerprint change (not the first load, not a fetch).
    public internal(set) var lastActivity: Date?
    /// Bumped by `refreshStatus()` whenever HEAD or the working tree changed — `CompareDiffView`
    /// keys its reload on it (a worktree endpoint's own store).
    public internal(set) var workingTreeVersion = 0
    /// The sidebar's unread dot: something changed since the user last had this repo selected.
    public var hasUnseenChanges: Bool { fingerprint != nil && lastViewedFingerprint != nil && fingerprint != lastViewedFingerprint }
    /// Called after `refreshStatus()` sees a new fingerprint (including the first) — `WorkspaceStore` persists from here.
    var onFingerprintChange: ((RepositoryStore) -> Void)?
    /// `RepoPrefs.reviewedHead` — HEAD as of the last "Mark Reviewed". `nil` = never reviewed.
    public internal(set) var reviewedHead: String?
    /// Commits in `reviewedHead..HEAD`; `nil` when never reviewed or the review point is gone.
    public internal(set) var unreviewedCount: Int?
    /// `reviewedHead` is no longer an ancestor of HEAD (reset/rebased away) — `..HEAD` means nothing.
    public internal(set) var reviewPointMissing = false
    /// `"<reviewedHead>-<headOID>"` the count was last computed for — skips the git call when neither moved.
    @ObservationIgnored var reviewStateKey: String?
    /// Called by `markReviewed()` — `WorkspaceStore` persists `reviewedHead` from here.
    var onMarkReviewed: ((RepositoryStore) -> Void)?
    /// Pull-request state via `gh` — see `RepositoryStore+PullRequests`. Never refreshed by `refreshStatus()`.
    public internal(set) var pullRequest: PullRequest?
    public internal(set) var lastGHError: String?
    /// `origin` is on github.com — nil until first checked, then cached.
    public internal(set) var hasGitHubRemote: Bool?
    /// Injectable for tests (fake `gh` script).
    @ObservationIgnored public var gh = GHRunner()
    /// Remote-tracking refs as of the last fetch — the "before" for `recordRemoteActivity`.
    @ObservationIgnored public internal(set) var remoteSnapshot: RemoteRefSnapshot?
    /// Mirrors `AppSettings.trackRemoteActivity` (kept in sync by `WorkspaceStore`).
    @ObservationIgnored public var tracksRemoteActivity = false
    /// Called with what a fetch/pull brought in, when `tracksRemoteActivity` and non-empty.
    @ObservationIgnored public var onRemoteActivity: (([ActivityEvent]) -> Void)?
    /// `RepoPrefs.agentPatterns` — nil falls back to `globalAgentProfile`.
    public internal(set) var agentPatterns: [String]?
    /// `RepoPrefs.fetchCadence` — which auto-fetch ticks visit this repo.
    public internal(set) var fetchCadence: FetchCadence = .normal
    /// Mirrors `AppSettings.agentProfile` (kept in sync by `WorkspaceStore`).
    public var globalAgentProfile = AgentProfile()
    /// Who counts as an agent in this repo: the per-repo override, else the global profile.
    public var agentProfile: AgentProfile { agentPatterns.map { AgentProfile(patterns: $0) } ?? globalAgentProfile }

    let git: GitRunner
    public nonisolated var id: URL { url }
    public let url: URL
    /// For a linked worktree, the main repo it belongs to (`<main>` from `<main>/.git/worktrees/<name>`),
    /// symlink-resolved; nil for a main checkout. Set once in `init` — a stat plus one small file read.
    public private(set) var worktreeParent: URL?

    public init(url: URL, prefs: RepoPrefs = RepoPrefs(), git: GitRunner = GitRunner()) {
        self.url = url
        self.git = git
        self.repo = Repository(id: url, tags: Set(prefs.tags), localAIOnly: prefs.localAIOnly)
        self.restoredSelectedPath = prefs.selectedPath
        self.restoredDraft = prefs.commitDraft
        self.restoredCompareBase = prefs.compareBase
        self.defaultRemote = prefs.defaultRemote
        self.lastViewedFingerprint = prefs.lastViewedFingerprint
        self.lastActivity = prefs.lastActivity
        self.reviewedHead = prefs.reviewedHead
        self.agentPatterns = prefs.agentPatterns
        self.fetchCadence = prefs.fetchCadence
        self.secretScanIgnoredPaths = Set(prefs.secretScanIgnoredPaths)
        if let gitDir = gitDirURL(), gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
            let dotGit = gitDir.deletingLastPathComponent().deletingLastPathComponent()
            if dotGit.lastPathComponent == ".git" { worktreeParent = dotGit.deletingLastPathComponent().resolvingSymlinksInPath() }
        }
    }

    public var stagedChanges: [FileChange] { partition.staged }
    /// Conflicted files get their own section (see `conflictedChanges`) rather than showing up
    /// here alongside ordinary unstaged edits.
    public var unstagedChanges: [FileChange] { partition.unstaged }
    public var untrackedChanges: [FileChange] { partition.untracked }
    public var conflictedChanges: [FileChange] { partition.conflicted }
    /// `repo.changes` by `FileChange.id` — O(1) lookups for selection reconciliation and the diff pane.
    public var changesByID: [String: FileChange] { partition.byID }
    /// Stuck mid-operation or holding conflicts — the sidebar's warning icon and "Attention" scope.
    public var needsAttention: Bool { operation != nil || !conflictedChanges.isEmpty }

    /// The prefs another window may have just changed — not the per-window UI state
    /// (selected file, draft, compare base) that `applyPrefs` also restores.
    public func applySharedPrefs(_ prefs: RepoPrefs) {
        repo.localAIOnly = prefs.localAIOnly
        defaultRemote = prefs.defaultRemote
        agentPatterns = prefs.agentPatterns
        fetchCadence = prefs.fetchCadence
        secretScanIgnoredPaths = Set(prefs.secretScanIgnoredPaths)
        // Only ever advance these: another window's write of an unrelated pref must not wipe the
        // in-memory baseline `refreshStatus()` adopted for a never-viewed repo.
        if let viewed = prefs.lastViewedFingerprint { lastViewedFingerprint = viewed }
        if let activity = prefs.lastActivity { lastActivity = activity }
        if let reviewed = prefs.reviewedHead { reviewedHead = reviewed }
    }

    /// Every secret scan's findings minus the files the user excluded. Path-less findings (the
    /// "diff too large to scan" note) always stay.
    public func withoutIgnoredSecrets(_ findings: [SecretScanner.Finding]) -> [SecretScanner.Finding] {
        findings.filter { $0.path.isEmpty || !secretScanIgnoredPaths.contains($0.path) }
    }

    public func applyPrefs(_ prefs: RepoPrefs) {
        repo.tags = Set(prefs.tags)
        secretScanIgnoredPaths = Set(prefs.secretScanIgnoredPaths)
        repo.localAIOnly = prefs.localAIOnly
        restoredSelectedPath = prefs.selectedPath
        restoredDraft = prefs.commitDraft
        restoredCompareBase = prefs.compareBase
        defaultRemote = prefs.defaultRemote
        agentPatterns = prefs.agentPatterns
        fetchCadence = prefs.fetchCadence
    }

    // MARK: - Status

    /// Bumped at the start of every `refreshStatus()` call; a run only writes its results if it's
    /// still the most recent one when it finishes. `refreshStatus` has ~46 call sites and no
    /// serialization, so overlapping runs (e.g. two FSEvents-debounced refreshes) can otherwise
    /// finish out of order and let a stale result overwrite a newer one.
    var statusGeneration = 0

    /// Called with what changed between two `refreshStatus()` results (never on the first one).
    @ObservationIgnored public var onEvents: (([RepoEvent]) -> Void)?
    @ObservationIgnored var hasLoadedStatus = false
    @ObservationIgnored var resolvedGitDir: URL?

    // MARK: - Diff

    /// `context`, when given, is passed as `-U<context>` — a huge value (e.g. 100000) makes git
    /// return the whole file as one hunk instead of the default 3-line-context hunks.
    public func diff(for change: FileChange, context: Int? = nil) async -> FileDiff? {
        lastError = nil
        do {
            let text: String
            let contextArgs = context.map { ["-U\($0)"] } ?? []
            switch (change.status, change.area) {
            case (.untracked, _):
                text = try await git.run(["diff", "--no-index"] + contextArgs + ["--", "/dev/null", change.path], in: url, allowedExitCodes: [0, 1])
            case (_, .staged):
                text = try await git.run(["diff", "--cached"] + contextArgs + ["--", change.path], in: url)
            case (_, .unstaged):
                text = try await git.run(["diff"] + contextArgs + ["--", change.path], in: url)
            }
            return DiffParser.parse(text).first
        } catch let e as GitError {
            lastError = e
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Actions

    public func stage(_ change: FileChange) async {
        await perform(["add", "-A", "--", change.path], literalPathspecs: true)
    }

    public func unstage(_ change: FileChange) async {
        await perform(["reset", "-q", "--", change.path], literalPathspecs: true)
    }

    public func stageAll() async {
        await perform(["add", "-A"])
    }

    /// `git reset -q`: unstages everything in one shot, mirroring `stageAll()`. A repo with
    /// unresolved conflicts should not call this directly — conflicted files are never staged
    /// (see `stagedChanges`), but resetting the whole index can still disturb their unmerged
    /// entries, so callers with conflicts present should loop `unstage(_:)` over `stagedChanges`
    /// instead, the same fallback `stageAll()`'s callers already use.
    public func unstageAll() async {
        await perform(["reset", "-q"])
    }

    /// Discards tracked, unstaged working-tree modifications only (`git restore --worktree`) —
    /// untracked files are never touched. Loops explicit paths from `unstagedChanges` (which
    /// already excludes untracked and conflicted files, see its doc comment) rather than a single
    /// `-- .` restore, so conflicted files are excluded the same way bulk stage/unstage already are.
    @discardableResult
    public func discardAllTracked() async -> Bool {
        let paths = unstagedChanges.map(\.path)
        guard !paths.isEmpty else { return true }
        return await perform(["restore", "--worktree", "--"] + paths, literalPathspecs: true)
    }

    /// Discards working tree changes. Untracked files are deleted.
    public func discard(_ change: FileChange) async {
        if change.status == .untracked {
            lastError = nil
            beginBusy()
            defer { endBusy() }
            do {
                try FileManager.default.removeItem(at: url.appendingPathComponent(change.path))
            } catch {
                lastError = GitError(args: ["rm", change.path], exitCode: -1, stderr: error.localizedDescription)
            }
            await refreshStatus()
        } else if change.area == .staged {
            await perform(["restore", "--staged", "--worktree", "--", change.path], literalPathspecs: true)
        } else {
            await perform(["restore", "--worktree", "--", change.path], literalPathspecs: true)
        }
    }

    /// Returns true on success. Hook failures land in `lastError`. `expectedHead` (amend only) is
    /// the commit whose message the user saw — see `headMoved`.
    public func commit(_ message: CommitMessage, amend: Bool = false, expectedHead: String? = nil) async -> Bool {
        var args = ["commit", "-q", "-F", "-"]
        if amend { args.append("--amend") }
        if await headMoved(from: expectedHead, args: args, what: "amended") { return false }
        return await perform(args, stdin: message.fullText)
    }

    /// `true` (with `lastError` set) when HEAD is no longer `expected` — an agent committed while a
    /// confirmation, the Reword sheet or the Amend toggle was up, and acting now would hit a
    /// different commit than the one the user looked at. `nil` means "whatever HEAD is now".
    /// ponytail: rev-parse then act is a few-ms window, not atomic; git has no compare-and-swap for these.
    func headMoved(from expected: String?, args: [String], what: String) async -> Bool {
        guard let expected, await headHash() != expected else { return false }
        lastError = GitError(args: args, exitCode: -1, stderr: "HEAD has moved since you chose that commit — nothing was \(what).")
        return true
    }

    /// Rewrites only HEAD's message: `--amend --only` with no paths ignores the index, so staged
    /// changes stay staged instead of being swept into the amend, and the tree is unchanged.
    /// `stripTrailers` is the UI's `stripAgentTrailers` setting (the store doesn't see settings).
    public func rewordHead(_ message: CommitMessage, stripTrailers: Bool, expectedHead: String? = nil) async -> Bool {
        let args = ["commit", "-q", "--amend", "--only", "--allow-empty", "-F", "-"]
        if let op = operation {
            lastError = GitError(args: args, exitCode: -1, stderr: "A \(op.label) is in progress — finish or abort it before rewording.")
            return false
        }
        guard repo.headOID != nil else {
            lastError = GitError(args: args, exitCode: -1, stderr: "There is no commit to reword yet.")
            return false
        }
        if await headMoved(from: expectedHead, args: args, what: "reworded") { return false }
        return await perform(args, stdin: (stripTrailers ? TrailerStripper.strip(message) : message).fullText)
    }

    /// HEAD's commit message, split into title (first line) and body (the rest, with leading
    /// blank lines trimmed) — the same shape `CommitMessage` uses for a draft. `nil` when HEAD
    /// has no commits.
    public func lastCommitMessage() async -> CommitMessage? {
        await lastCommit()?.message
    }

    /// HEAD's hash and message from one `git log`, so the hash is exactly the commit the message
    /// came from — what Reword/Amend pass back as `expectedHead`.
    public func lastCommit() async -> (hash: String, message: CommitMessage)? {
        guard let out = try? await git.run(["log", "-1", "--pretty=%H%n%B"], in: url),
              let newline = out.firstIndex(of: "\n") else { return nil }
        let hash = String(out[..<newline])
        let raw = String(out[out.index(after: newline)...])
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let title = lines.removeFirst()
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return (hash, CommitMessage(title: title, body: body))
    }

    /// `git reset --soft HEAD~1`: drops the last commit but leaves the index untouched, so
    /// everything it contained lands back in the staging area — nothing is lost, and the user can
    /// re-commit immediately. Never `--hard`/`--mixed`, which is the whole point of this action.
    ///
    /// `expectedHead` guards the gap between a confirmation dialog and this call: the user picks a
    /// specific commit in the History list, and in a workspace where agents commit continuously
    /// HEAD can move while the dialog is up — resetting then would silently undo a *different*
    /// commit than the one they looked at. Callers that genuinely mean "whatever HEAD is now"
    /// (the ⌘K action) pass nil.
    @discardableResult
    public func undoLastCommit(expectedHead: String? = nil) async -> Bool {
        let args = ["reset", "--soft", "HEAD~1"]
        if await headMoved(from: expectedHead, args: args, what: "undone") { return false }
        return await perform(args)
    }

    // MARK: - Clean untracked files (git clean)

    /// `git clean -n` (plus `-d` when `includeDirectories`), parsed by `CleanPreviewParser`.
    /// Never passes `-x`/`-X` — ignored files must never show up here, matching plain `git clean`'s
    /// own default of leaving them alone. Returns the raw "Would remove " paths (directories keep
    /// their trailing `/`), the same strings `clean(paths:)` expects back.
    public func cleanPreview(includeDirectories: Bool) async -> [String] {
        var args = ["clean", "-n"]
        if includeDirectories { args.append("-d") }
        let out = (try? await git.run(args, in: url)) ?? ""
        return CleanPreviewParser.parse(out)
    }

    /// `git clean -f [-d] -- <paths>`: deletes exactly the paths passed in, never a fresh `clean -n`
    /// lookup — so a file an agent wrote after the preview was shown is left untouched, and what the
    /// user confirmed is exactly what goes.
    @discardableResult
    public func clean(paths: [String], includeDirectories: Bool) async -> Bool {
        guard !paths.isEmpty else { return true }
        var args = ["clean", "-f"]
        if includeDirectories { args.append("-d") }
        // `GitRunner` sets `GIT_LITERAL_PATHSPECS=1` — a previewed name like `a[1].txt` is treated
        // literally rather than as a glob pathspec that would also match (and delete) an
        // unpreviewed `a1.txt`.
        return await perform(args + ["--"] + paths, literalPathspecs: true)
    }

    // MARK: - .gitignore

    /// Appends `pattern` as a new line to the repo-root `.gitignore` (created if missing), via
    /// `GitignoreEditor` — deduped against an existing identical line, trailing newline ensured
    /// before appending. Returns `false` both when the pattern was already present (nothing to do)
    /// and on a real write failure (surfaced through `lastError`, same convention as every other
    /// action here); callers that need to tell those apart can check `lastError`.
    @discardableResult
    public func addToGitignore(_ pattern: String) async -> Bool {
        let path = url.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let updated = GitignoreEditor.appending(pattern, to: existing) else { return false }
        lastError = nil
        do {
            try updated.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            lastError = GitError(args: ["gitignore", "append"], exitCode: -1, stderr: error.localizedDescription)
            return false
        }
        await refreshStatus()
        return true
    }

    // MARK: - Conflicts

    /// Resolves a conflicted file by taking "our" side and marking it resolved (`git add`).
    /// During a normal merge, "ours" is the branch you're on and "theirs" is the branch being
    /// merged in — but during a `rebase`, git flips that: "ours" is the upstream commit being
    /// replayed onto and "theirs" is your own commit (verified against real git output — see
    /// `RemoteOpsTests`/rebase-conflict tests). The `git checkout --ours`/`--theirs` flag passed
    /// here is identical either way; only the view layer's *labels* differ by `rebaseInProgress`
    /// ("Keep Upstream"/"Keep My Commit" during a rebase vs. "Use Mine"/"Use Theirs" during a merge)
    /// so the button text never says something backwards.
    @discardableResult
    public func useOurs(_ change: FileChange) async -> Bool {
        await resolveConflict(change, flag: "--ours")
    }

    @discardableResult
    public func useTheirs(_ change: FileChange) async -> Bool {
        await resolveConflict(change, flag: "--theirs")
    }

    private func resolveConflict(_ change: FileChange, flag: String) async -> Bool {
        await exec(["checkout", flag, "--", change.path], ["add", "--", change.path]) { $0.failure == nil }
    }

    /// Throws away the in-progress merge and any conflict resolution done so far, restoring the
    /// pre-merge working tree. Destructive — callers must confirm before calling this.
    @discardableResult
    public func abortMerge() async -> Bool {
        await perform(["merge", "--abort"])
    }

    // MARK: - Stash

    /// `git stash push -u`. `-u` also stashes untracked files — without it they stay behind and a
    /// caller relying on this to leave a clean tree (e.g. "stash and switch") would be lied to.
    ///
    /// Returns `false` both on a real failure (surfaced through `lastError`, same as any other git
    /// command) and on git's clean-tree no-op — `git stash push` on a clean tree exits 0 and prints
    /// "No local changes to save" rather than failing, so that text is checked for explicitly.
    /// Callers must not report that case as a successful stash; `lastError` stays nil for it, so
    /// it's distinguishable from a real failure if that distinction matters.
    @discardableResult
    public func stash(message: String? = nil) async -> Bool {
        var args = ["stash", "push", "-u"]
        if let message { args += ["-m", message] }
        return await exec(args) { result in
            await refreshStashCount()
            return (try? result.get()).map { !$0.stdout.contains("No local changes to save") } ?? false
        }
    }

    /// `git stash pop`. A pop that conflicts (the popped stash touches lines the working tree has
    /// since changed) exits non-zero and leaves conflict markers plus the stash entry in place —
    /// `perform` already routes any non-zero exit to `lastError` and returns `false`, so a
    /// conflicted pop is never mistaken for success here.
    @discardableResult
    public func stashPop() async -> Bool {
        let ok = await perform(["stash", "pop"])
        await refreshStashCount()
        return ok
    }

    public func refreshStashCount() async {
        guard let out = try? await git.run(["stash", "list"], in: url) else { return }
        stashCount = out.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    // MARK: - Hunks

    /// `DiffParser` records "\ No newline at end of file" per line and `PatchBuilder` re-emits it,
    /// so hunks touching an unterminated last line apply too.
    /// Stages one hunk of a modified file via `git apply --cached`.
    @discardableResult
    public func stageHunk(_ hunk: Hunk, of change: FileChange) async -> Bool {
        await perform(["apply", "--cached", "--whitespace=nowarn"], stdin: PatchBuilder.patch(path: change.path, hunk: hunk))
    }

    /// Reverses one staged hunk out of the index (working tree untouched).
    @discardableResult
    public func unstageHunk(_ hunk: Hunk, of change: FileChange) async -> Bool {
        await perform(["apply", "--cached", "--reverse", "--whitespace=nowarn"], stdin: PatchBuilder.patch(path: change.path, hunk: hunk))
    }

    /// Contents of `path` at HEAD, or nil when the file is not in HEAD.
    public func headContent(of path: String) async -> Data? {
        try? await git.runData(["show", "HEAD:\(path)"], in: url)
    }

    // MARK: - Rebase continue / skip / abort

    /// `git rebase --continue`, after the user has resolved the conflicted files and staged them.
    /// `-c core.editor=true` skips the commit-message editor `--continue` would otherwise try to
    /// launch for the replayed commit (there's no terminal to edit it in here) — `true` succeeds
    /// immediately and leaves the message untouched, the same trick `git rebase --continue` itself
    /// documents for non-interactive use.
    @discardableResult
    public func continueRebase() async -> Bool {
        await perform(["-c", "core.editor=true", "rebase", "--continue"])
    }

    /// Drops the commit currently being replayed and moves on to the next one (or finishes).
    @discardableResult
    public func skipRebase() async -> Bool {
        await perform(["rebase", "--skip"])
    }

    /// Throws away the in-progress rebase and any conflict resolution done so far, restoring the
    /// branch to its pre-rebase state. Destructive — callers must confirm before calling this,
    /// same as `abortMerge`.
    @discardableResult
    public func abortRebase() async -> Bool {
        await perform(["rebase", "--abort"])
    }

    // MARK: - Cherry-pick & revert

    /// `git cherry-pick <hash>`: applies that commit's changes as a new commit on the current
    /// branch. A conflict leaves `CHERRY_PICK_HEAD` behind (picked up by the next `refreshStatus()`
    /// as `operation == .cherryPick`) rather than throwing here — same shape as every other
    /// conflict-producing action in this file.
    @discardableResult
    public func cherryPick(_ hash: String) async -> Bool {
        await perform(["cherry-pick", hash])
    }

    /// `git revert --no-edit <hash>`: creates a new commit that undoes `hash` — nothing is deleted
    /// from history, which is what makes this safe for a commit that's already been pushed.
    /// `mainline`, when given, is passed as `-m <mainline>` — required for a merge commit, since
    /// `git revert` can't otherwise tell which parent to revert relative to. Callers pass
    /// `commit.parentCount > 1 ? 1 : nil` (see `RevertRunner` in the UI layer): mainline 1 undoes
    /// the merge relative to the branch it was merged into, which is what "revert this merge" means
    /// in the common case of backing out a feature branch merge.
    @discardableResult
    public func revertCommit(_ hash: String, mainline: Int? = nil) async -> Bool {
        var args = ["revert", "--no-edit"]
        if let mainline { args += ["-m", "\(mainline)"] }
        args.append(hash)
        return await perform(args)
    }

    // MARK: - Operation in progress (merge / rebase / cherry-pick / revert)

    /// `git merge --continue`, `rebase --continue`, `cherry-pick --continue` or `revert --continue`
    /// depending on `operation` — the "Continue" button on `ChangesView`'s operation banner. For a
    /// merge this is what actually commits the resolution (the plan's "For merge, 'Continue' means
    /// commit the resolution"). `-c core.editor=true` suppresses the commit-message editor every one
    /// of these would otherwise try to launch — same trick `continueRebase` already used, verified
    /// to also work for cherry-pick/revert (`GIT_EDITOR=false`, its equivalent, was checked against
    /// real git in the exploration for this task).
    @discardableResult
    public func continueOperation() async -> Bool {
        switch operation {
        case .merge: return await perform(["-c", "core.editor=true", "merge", "--continue"])
        case .rebase: return await continueRebase()
        case .cherryPick: return await perform(["-c", "core.editor=true", "cherry-pick", "--continue"])
        case .revert: return await perform(["-c", "core.editor=true", "revert", "--continue"])
        case .bisect, nil: return false
        }
    }

    /// Only meaningful for a rebase or a cherry-pick sequence (drops the commit currently being
    /// replayed/applied and moves to the next one) — merge has no such concept, and this app's
    /// banner never offers Skip during a revert (see the plan). Returns `false` for those, same as
    /// calling any other action with nothing in progress.
    @discardableResult
    public func skipOperation() async -> Bool {
        switch operation {
        case .rebase: return await skipRebase()
        case .cherryPick: return await perform(["cherry-pick", "--skip"])
        case .merge, .revert, .bisect, nil: return false
        }
    }

    /// Throws away whatever's in progress and any conflict resolution done so far. Destructive —
    /// callers must confirm before calling this, same as `abortMerge`/`abortRebase`.
    @discardableResult
    public func abortOperation() async -> Bool {
        switch operation {
        case .merge: return await abortMerge()
        case .rebase: return await abortRebase()
        case .cherryPick: return await perform(["cherry-pick", "--abort"])
        case .revert: return await perform(["revert", "--abort"])
        case .bisect: return await bisectReset() == nil
        case nil: return false
        }
    }

    public func stagedDiffForAI() async -> (stat: String, diff: String) {
        async let stat = (try? await git.run(["diff", "--cached", "--stat"], in: url)) ?? ""
        async let diff = stagedDiff()
        return (await stat, await diff)
    }

    /// `git diff --cached` — what the commit gate scans for secrets.
    public func stagedDiff() async -> String {
        (try? await git.run(["diff", "--cached"], in: url)) ?? ""
    }

    @discardableResult
    func perform(_ args: [String], stdin: String? = nil, literalPathspecs: Bool = false) async -> Bool {
        await exec(args, stdin: stdin, literalPathspecs: literalPathspecs) { $0.failure == nil }
    }

    // MARK: - Running git for an action

    typealias GitOutput = (stdout: String, stderr: String)

    /// A user action's git commands, run in order until one fails: clears `lastError` and holds
    /// `isBusy` until `finish` returns. The failure goes to `lastError` (unless `recordError` is
    /// false — `finish` then decides), status is refreshed (skipped when git never ran, exit -1, and
    /// `refreshOnLaunchFailure` is false), and `finish` maps the last command's output.
    func exec<T>(_ commands: [String]..., stdin: String? = nil, literalPathspecs: Bool = false,
                 recordError: Bool = true, refreshOnLaunchFailure: Bool = true,
                 then finish: (Result<GitOutput, GitError>) async -> T) async -> T {
        lastError = nil
        beginBusy()
        defer { endBusy() }
        var result: Result<GitOutput, GitError> = .success(("", ""))
        for args in commands {
            do {
                result = .success(try await git.runCombined(args, in: url, stdin: stdin, literalPathspecs: literalPathspecs))
            } catch {
                result = .failure(Self.gitError(error, args))
                break
            }
        }
        if recordError, let e = result.failure { lastError = e }
        if refreshOnLaunchFailure || result.failure?.exitCode != -1 { await refreshStatus() }
        return await finish(result)
    }

    /// Runs `body`, refreshes status, and returns the failure (a non-`GitError` one reported as
    /// `GitError(args, -1, …)`). For actions that report through their return value rather than
    /// `lastError`, unless `recordError` also stores it there before the refresh.
    func attempt(_ args: [String], recordError: Bool = false, _ body: () async throws -> Void) async -> GitError? {
        var failure: GitError?
        do { try await body() } catch { failure = Self.gitError(error, args) }
        if recordError { lastError = failure }
        await refreshStatus()
        return failure
    }

    func attempt(_ args: [String], env: [String: String] = [:], allowedExitCodes: Set<Int32> = [0]) async -> GitError? {
        await attempt(args) { _ = try await git.runCombined(args, in: url, allowedExitCodes: allowedExitCodes, extraEnvironment: env) }
    }

    /// Like the above, but runs in `dir` instead of `url` — a nested submodule's commands run from
    /// its parent submodule's checkout, since it isn't recorded in this repo's own index.
    func attempt(_ args: [String], in dir: URL, env: [String: String] = [:], allowedExitCodes: Set<Int32> = [0]) async -> GitError? {
        await attempt(args) { _ = try await git.runCombined(args, in: dir, allowedExitCodes: allowedExitCodes, extraEnvironment: env) }
    }

    /// `GitRunner` already wraps launch failures (exit code -1); this covers `CancellationError`
    /// and non-git steps (`FileManager`), which these non-throwing helpers still report as failures.
    private static func gitError(_ error: Error, _ args: [String]) -> GitError {
        error as? GitError ?? GitError(args: args, exitCode: -1, stderr: error.localizedDescription)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

/// `repo.changes` split into the Changes list's sections plus an id index, built in one pass.
struct ChangePartition {
    var staged: [FileChange] = [], unstaged: [FileChange] = [], untracked: [FileChange] = [], conflicted: [FileChange] = []
    var byID: [String: FileChange] = [:]

    init(_ changes: [FileChange]) {
        byID.reserveCapacity(changes.count)
        for change in changes {
            byID[change.id] = change
            // Same predicates as the old per-read filters (not an else-chain), so nothing moves sections.
            if change.area == .staged { staged.append(change) }
            if change.area == .unstaged && change.status != .untracked && change.status != .conflicted { unstaged.append(change) }
            if change.status == .untracked { untracked.append(change) }
            if change.status == .conflicted { conflicted.append(change) }
        }
    }
}
