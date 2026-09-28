import Foundation

/// Tags, branch-from-commit, and merged-branch cleanup.
extension RepositoryStore {
    // MARK: - Tags

    public func tags() async -> [GitTag] {
        let out = try? await git.run(["for-each-ref", "refs/tags", "--format=\(TagParser.format)"], in: url)
        return TagParser.parse(out ?? "")
    }

    /// Loads `gitTags` — History calls this once per load and maps hash → tags from it
    /// (`TagParser.byCommit`), so rows never spawn git themselves.
    public func refreshTags() async {
        gitTags = await tags()
    }

    /// `git tag <name> <hash>`, or `git tag -a <name> -m <message> <hash>` when `message` is non-empty.
    /// Name validated with `git check-ref-format refs/tags/<name>` and against an existing tag first.
    @discardableResult
    public func createTag(_ name: String, at hash: String, message: String? = nil) async -> RefCreateOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidName("Tag name can't be empty") }
        guard (try? await git.run(["check-ref-format", "refs/tags/\(trimmed)"], in: url)) != nil else {
            return .invalidName("\"\(trimmed)\" isn't a valid tag name")
        }
        if (try? await git.run(["rev-parse", "-q", "--verify", "refs/tags/\(trimmed)"], in: url)) != nil { return .duplicateName }
        let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let args = msg.isEmpty ? ["tag", trimmed, hash] : ["tag", "-a", trimmed, "-m", msg, hash]
        let ok = await perform(args)
        await refreshTags()
        return ok ? .succeeded : .failed(lastError?.stderr ?? "git tag failed")
    }

    @discardableResult
    public func deleteTag(_ name: String) async -> Bool {
        let ok = await perform(["tag", "-d", name])
        await refreshTags()
        return ok
    }

    /// Detached checkout of a tag's commit. The detached-HEAD UI itself is owned elsewhere.
    @discardableResult
    public func checkoutTag(_ name: String) async -> Bool {
        await perform(["checkout", "-q", "--detach", "refs/tags/\(name)"])
    }

    @discardableResult
    public func pushTag(_ name: String) async -> Bool {
        guard let remote = await requireTagRemote() else { return false }
        return await perform(["push", remote, "refs/tags/\(name)"])
    }

    /// `git push <remote> --delete refs/tags/<name>` — affects everyone using that remote.
    @discardableResult
    public func deleteRemoteTag(_ name: String) async -> Bool {
        guard let remote = await requireTagRemote() else { return false }
        return await perform(["push", remote, "--delete", "refs/tags/\(name)"])
    }

    @discardableResult
    public func pushAllTags() async -> Bool {
        guard let remote = await requireTagRemote() else { return false }
        return await perform(["push", remote, "--tags"])
    }

    /// The remote tag pushes go to: the current branch's upstream remote, else `origin`, else the
    /// first remote — same preference as `push()`'s first push. `nil` when there's no remote.
    public func tagRemote() async -> String? {
        if let upstreamRemote { return upstreamRemote }
        return RemoteSelection.pushRemote(from: await remoteList(), preferred: nil)
    }

    private func requireTagRemote() async -> String? {
        if let remote = await tagRemote() { return remote }
        lastError = GitError(args: ["push"], exitCode: -1, stderr: "\(RemoteOutputParser.noRemoteMessage) Add one with `git remote add origin <url>`.")
        return nil
    }

    // MARK: - Branch from a commit

    /// `git branch <name> <hash>`, or `git switch -c <name> <hash>` when `checkout`. Validated with
    /// `git check-ref-format --branch` and against existing local branches first.
    @discardableResult
    public func createBranch(_ name: String, at hash: String, checkout: Bool) async -> RefCreateOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await branchNameProblem(trimmed) { return .invalidName(problem) }
        let exists = (try? await git.run(["rev-parse", "-q", "--verify", "refs/heads/\(trimmed)"], in: url)) != nil
        if exists { return .duplicateName }
        let ok = await perform(checkout ? ["switch", "-q", "-c", trimmed, hash] : ["branch", trimmed, hash])
        return ok ? .succeeded : .failed(lastError?.stderr ?? "git failed")
    }

    // MARK: - Merged-branch cleanup

    /// The base the user sees in Compare (`baseBranch()`) and the local branches fully merged into
    /// it, minus the current branch and the base itself. `nil` when no base can be resolved.
    public func mergedBranchCandidates() async -> (base: String, branches: [String])? {
        guard let base = await baseBranch() else { return nil }
        let out = (try? await git.run(["for-each-ref", "--merged", base, "--format=%(refname)", "refs/heads"], in: url)) ?? ""
        let merged = out.split(separator: "\n").map { String($0.dropFirst("refs/heads/".count)) }
        return (base, MergedCleanup.candidates(merged: merged, base: base, current: repo.branch))
    }

    /// `git branch -d` for each — never `-D`. git checks "merged" against the branch's upstream (or
    /// HEAD), not our base, so it can still refuse; those come back in `refused` with git's reason.
    public func deleteMergedBranches(_ names: [String]) async -> MergedCleanupResult {
        var deleted: [String] = []
        var refused: [(name: String, reason: String)] = []
        for name in names {
            do {
                try await git.run(["branch", "-d", name], in: url)
                deleted.append(name)
            } catch let e as GitError {
                let firstLine = e.stderr.split(separator: "\n").first.map(String.init) ?? "refused"
                refused.append((name, firstLine))
            } catch {
                refused.append((name, error.localizedDescription))
            }
        }
        await refreshStatus()
        return MergedCleanupResult(deleted: deleted, refused: refused)
    }
}
