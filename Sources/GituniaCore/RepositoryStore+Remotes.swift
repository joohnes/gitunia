import Foundation

/// Remotes and upstream management. Remote edits (`addRemote`/`renameRemote`/`setRemoteURL`/
/// `removeRemote`) return their failure instead of setting `lastError`: the Remotes sheet shows it
/// inline, and it can be opened for a repo that isn't selected (sidebar context menu), where
/// `ContentView`'s generic `lastError` toast watcher wouldn't see it anyway.
extension RepositoryStore {
    // MARK: - Reading

    public func listRemotes() async -> [RemoteInfo] {
        let remotes = RemoteListParser.parse((try? await git.run(["remote", "-v"], in: url)) ?? "")
        remoteNames = remotes.map(\.name)
        return remotes
    }

    public func refreshRemotes() async {
        _ = await listRemotes()
    }

    /// What removing `name` would take with it, for the confirmation.
    public func removalImpact(of name: String) async -> RemoteRemovalImpact {
        let out = (try? await git.run(["for-each-ref", "--format=%(refname)%09%(upstream:remotename)",
                                       "refs/heads", "refs/remotes/\(name)/"], in: url)) ?? ""
        return RemoteRemovalImpact.parse(out, remote: name)
    }

    /// The remote `fetch()` should name explicitly: the default remote, but only when the current
    /// branch has no upstream (with one, plain `git fetch` already uses the upstream's remote) and
    /// the default still exists. `nil` = plain `git fetch`, the pre-existing behaviour.
    func defaultFetchRemote() async -> String? {
        guard !hasUpstream, let preferred = defaultRemote else { return nil }
        return await remoteList().contains(preferred) ? preferred : nil
    }

    /// `git remote` names, live (not the cached `remoteNames`); empty when git fails.
    func remoteList() async -> [String] {
        ((try? await git.run(["remote"], in: url)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: - Fetch from a specific remote

    @discardableResult
    public func fetch(from remote: String) async -> RemoteResult {
        await performRemote(.fetch, ["fetch", "--prune", "--", remote], remote: remote)
    }

    // MARK: - Editing remotes

    /// Mirrors git's own `valid_remote_name` (`refs/remotes/<name>/test` must be a valid ref),
    /// plus a duplicate check, before git runs — so the sheet can say *why*.
    public func validateRemoteName(_ name: String, excluding current: String? = nil) async -> String? {
        let existing = await listRemotes().map(\.name).filter { $0 != current }
        if let problem = RemoteValidation.nameProblem(name, existing: existing) { return problem }
        do {
            _ = try await git.run(["check-ref-format", "refs/remotes/\(name)/test"], in: url)
            return nil
        } catch {
            return "\"\(name)\" isn't a valid remote name"
        }
    }

    public func addRemote(name: String, url remoteURL: String) async -> RemoteEditResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await validateRemoteName(name) { return .invalid(problem) }
        if let problem = RemoteValidation.urlProblem(remoteURL) { return .invalid(problem) }
        return await runRemoteEdit(["remote", "add", "--", name, remoteURL])
    }

    /// `git remote rename` also moves the remote-tracking refs and every `branch.*.remote` pointing
    /// at it, so upstreams follow the rename.
    public func renameRemote(_ name: String, to newName: String) async -> RemoteEditResult {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName == name { return .invalid("That's already this remote's name") }
        if let problem = await validateRemoteName(newName, excluding: name) { return .invalid(problem) }
        return await runRemoteEdit(["remote", "rename", "--", name, newName])
    }

    public func setRemoteURL(_ name: String, to remoteURL: String) async -> RemoteEditResult {
        let remoteURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = RemoteValidation.urlProblem(remoteURL) { return .invalid(problem) }
        return await runRemoteEdit(["remote", "set-url", "--", name, remoteURL])
    }

    /// Deletes the remote, its remote-tracking refs, and the upstream config of branches tracking
    /// it (see `removalImpact(of:)`). Destructive locally only — nothing is sent to the remote.
    public func removeRemote(_ name: String) async -> RemoteEditResult {
        await runRemoteEdit(["remote", "remove", "--", name])
    }

    private func runRemoteEdit(_ args: [String]) async -> RemoteEditResult {
        let result: RemoteEditResult
        do {
            try await git.run(args, in: url)
            result = .succeeded
        } catch let e as GitError {
            result = .failed(e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            result = .failed(URLRedaction.redact(error.localizedDescription))
        }
        // `origin` may now point somewhere else (or nowhere) — the PR toolbar's cached
        // "is this GitHub" check and any stale pull request must be re-evaluated, not reused.
        hasGitHubRemote = nil
        pullRequest = nil
        await refreshRemotes()
        await refreshStatus()
        return result
    }

    // MARK: - Upstream

    /// `git branch --set-upstream-to=refs/remotes/<remoteBranch> <current>`. `remoteBranch` is a
    /// remote `BranchInfo.name` (`"origin/main"`); the full ref avoids ambiguity with a local
    /// branch literally named `origin/main`. Failures go through `lastError` (toolbar path).
    @discardableResult
    public func setUpstream(to remoteBranch: String) async -> Bool {
        guard let branch = currentLocalBranch else { return false }
        return await perform(["branch", "--set-upstream-to=refs/remotes/\(remoteBranch)", branch])
    }

    @discardableResult
    public func unsetUpstream() async -> Bool {
        guard let branch = currentLocalBranch else { return false }
        return await perform(["branch", "--unset-upstream", branch])
    }

    private var currentLocalBranch: String? {
        guard let branch = repo.branch, !branch.isEmpty, !repo.isDetached else { return nil }
        return branch
    }
}
