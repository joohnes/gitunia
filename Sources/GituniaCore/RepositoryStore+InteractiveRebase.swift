import Foundation

// MARK: - Tidy commits (interactive rebase without an editor)

extension RepositoryStore {
    /// Commits on HEAD the upstream doesn't have (`@{upstream}..HEAD`), newest first — the ones
    /// safe to rewrite. Without an upstream, the last `limit` commits.
    public func rewritableCommits(limit: Int = 50) async -> [CommitInfo] {
        await history(limit: limit, filterArgs: hasUpstream ? ["@{upstream}..HEAD"] : [])
    }

    /// Why Tidy Commits can't start right now, or nil. The pushed-commit check needs git, so it
    /// lives in `interactiveRebase` instead.
    public var interactiveRebaseBlocker: String? {
        if let blocker = RebasePlan.blocker(repo: repo, operation: operation) { return blocker }
        let dirty = repo.changes.filter { $0.status != .untracked }.count
        if dirty > 0 { return "\(dirty) uncommitted change\(dirty == 1 ? "" : "s") — stash or commit first" }
        return nil
    }

    /// Runs `git rebase -i` over `lines` (oldest first; must be exactly the newest N commits of
    /// HEAD, else the ones left out would silently vanish). The todo is copied in by
    /// `GIT_SEQUENCE_EDITOR`, `GIT_EDITOR=true` keeps squash/reword from prompting, and messages
    /// come from `exec git commit --amend -F` lines (see `RebaseTodo.render`). Stopping on
    /// conflicts is not an error: `operation` becomes `.rebase` and the banner takes over.
    public func interactiveRebase(_ lines: [RebaseTodo.Line]) async -> GitError? {
        func refuse(_ why: String) -> GitError { GitError(args: ["rebase", "-i"], exitCode: -1, stderr: why) }
        if let why = interactiveRebaseBlocker ?? RebaseTodo.validate(lines) { return refuse(why) }

        let tip = ((try? await git.run(["rev-list", "-n", "\(lines.count)", "HEAD"], in: url)) ?? "")
            .split(separator: "\n").map(String.init)
        guard let oldest = tip.last, Set(tip) == Set(lines.map(\.hash)) else {
            return refuse("HEAD moved since the list was shown — reopen it and try again")
        }
        if hasUpstream {
            switch await isAncestor(oldest, of: "@{upstream}") {
            case false?: break
            case true?: return refuse("Some of these commits are already pushed — rewriting them would need a force push")
            case nil: return refuse("Couldn't check whether these commits are already pushed — fetch and try again")
            }
        }
        let parent = (try? await git.run(["rev-parse", "--verify", "-q", "\(oldest)^"], in: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let merges = (try? await git.run(["rev-list", "--merges", "-n", "1", parent.map { "\($0)..HEAD" } ?? "HEAD"], in: url)) ?? ""
        if !merges.isEmpty { return refuse("There's a merge commit in this range — tidying can't keep it") }

        // Swept on launch by `AppDataLocation.cleanupTemp` (B11) once older than 24h — a
        // conflict-stopped rebase still needs the message files when it's continued later, so
        // nothing deletes this right away. Own subfolder so the sweep never lists all of `$TMPDIR`.
        let dir = AppDataLocation.rebaseTempDirectory.appendingPathComponent(UUID().uuidString)
        var messageFiles: [Int: String] = [:]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, line) in lines.enumerated() {
                guard line.action == .reword || line.action == .squash,
                      let message = line.newMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { continue }
                let file = dir.appendingPathComponent("msg-\(i)")
                try (message + "\n").write(to: file, atomically: true, encoding: .utf8)
                messageFiles[i] = file.path
            }
            try RebaseTodo.render(lines, messageFiles: messageFiles)
                .write(to: dir.appendingPathComponent("todo"), atomically: true, encoding: .utf8)
        } catch {
            return refuse(error.localizedDescription)
        }

        let args = ["rebase", "-i", parent ?? "--root"]
        let env = ["GIT_SEQUENCE_EDITOR": "/bin/cp \(RebaseTodo.shellQuoted(dir.appendingPathComponent("todo").path))",
                   "GIT_EDITOR": "true"]
        beginBusy()
        defer { endBusy() }
        let failure = await attempt(args, env: env)
        return operation == .rebase ? nil : failure
    }
}
