import Foundation

/// Recovery tools: reflog, reset to a commit, detached-HEAD checkout.
extension RepositoryStore {
    /// `git reflog` for HEAD, newest first. Empty for a repository with no commits (git exits 128
    /// there: "your current branch 'main' does not have any commits yet").
    public func reflog() async -> [ReflogEntry] {
        let out = try? await git.run(["reflog", "-n", "500", "--date=unix", "--format=\(ReflogParser.format)"], in: url)
        return ReflogParser.parse(out ?? "")
    }

    /// What `reset(to:)` would take off the current branch. `pushed` counts undone commits that
    /// some remote-tracking branch already has (`HEAD --not <target> --remotes` is the local-only
    /// remainder).
    public func resetImpact(to target: String) async -> ResetImpact {
        let undone = await revCount(["HEAD", "--not", target])
        guard undone > 0 else { return ResetImpact(undone: 0, pushed: 0) }
        let localOnly = await revCount(["HEAD", "--not", target, "--remotes"])
        return ResetImpact(undone: undone, pushed: undone - localOnly)
    }

    /// `git reset --soft|--mixed|--hard <hash>` on the current branch. `expectedHead` guards the
    /// gap between the confirmation and this call, same as `undoLastCommit(expectedHead:)`: an
    /// agent committing meanwhile would otherwise have its new commit silently undone too.
    @discardableResult
    public func reset(to hash: String, mode: ResetMode, expectedHead: String? = nil) async -> Bool {
        let args = ["reset", "-q", "--\(mode.rawValue)", hash]
        if let expectedHead, await headHash() != expectedHead {
            lastError = GitError(args: args, exitCode: -1, stderr: "HEAD has moved since you chose to reset — nothing was reset.")
            return false
        }
        return await perform(args)
    }

    /// `git checkout --detach <hash>`: HEAD points at the commit, no branch moves.
    @discardableResult
    public func checkoutDetached(_ hash: String) async -> Bool {
        await perform(["checkout", "-q", "--detach", hash])
    }

    /// `git branch <name> <hash>` — creates the branch without switching to it (the safe choice
    /// from the reflog). To attach a detached HEAD, use `createBranch(_:)`, which checks it out.
    @discardableResult
    public func createBranch(_ name: String, at hash: String) async -> Bool {
        await perform(["branch", name, hash])
    }

    /// Commits reachable from HEAD but from no branch, tag or remote — what switching away from a
    /// detached HEAD would leave behind. Matches git's own "you are leaving N commits behind"
    /// count (verified against git 2.50.1).
    public func commitsOnlyOnHead() async -> Int {
        await revCount(["HEAD", "--not", "--branches", "--tags", "--remotes"])
    }

    /// `git rev-list --count <args>`; 0 when git fails.
    func revCount(_ args: [String]) async -> Int {
        Int(((try? await git.run(["rev-list", "--count"] + args, in: url)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// `git merge-base --is-ancestor`: exit 0 = yes, 1 = no, anything else (unresolvable ref, gc'd
    /// object) = `nil`, unknown — `try?` alone would read that as "no".
    func isAncestor(_ ancestor: String, of descendant: String) async -> Bool? {
        do {
            try await git.run(["merge-base", "--is-ancestor", ancestor, descendant], in: url)
            return true
        } catch let error as GitError where error.exitCode == 1 {
            return false
        } catch {
            return nil
        }
    }

    public func headHash() async -> String? {
        (try? await git.run(["rev-parse", "HEAD"], in: url))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
