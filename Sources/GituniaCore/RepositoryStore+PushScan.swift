import Foundation

// MARK: - Secret scan of unpushed commits

extension RepositoryStore {
    /// Secret-looking lines added by the commits a push of `branch` (default: the current one)
    /// would send. Agents can commit on their own, bypassing the commit-time scan in `CommitBox`,
    /// so this is the last chance before the remote. Range: `<branch>@{upstream}..<branch>`; with
    /// no upstream, `<remote>/<branch>..` for the remote a first push would use, else everything
    /// not on any remote. Never returns matched values.
    public func unpushedSecretFindings(branch: String? = nil) async -> [SecretScanner.Finding] {
        // The common case — nothing unpushed — never shells out.
        if branch == nil || branch == repo.branch, hasUpstream, upstreamMatchesBranch, repo.ahead == 0 { return [] }
        let tip = branch ?? "HEAD"
        func exists(_ rev: String) async -> Bool {
            (try? await git.run(["rev-parse", "-q", "--verify", rev + "^{commit}"], in: url)) != nil
        }
        let upstream = "\(branch ?? "")@{upstream}"
        var range: [String]
        if await exists(upstream) {
            range = ["\(upstream)..\(tip)"]
        } else {
            range = [tip, "--not", "--remotes"]
            let current = ((try? await git.run(["symbolic-ref", "--short", "HEAD"], in: url)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = branch ?? current
            if !name.isEmpty, let remote = RemoteSelection.pushRemote(from: await remoteList(), preferred: defaultRemote),
               await exists("refs/remotes/\(remote)/\(name)") {
                range = ["refs/remotes/\(remote)/\(name)..\(tip)"]
            }
        }
        // ponytail: whole log read into memory before the size check — fine at 200 commits; stream if it bites.
        guard let data = try? await git.runData(
            ["log", "-p", "-n", "200", "--format=%H%x1f%s", "--no-color"] + range + ["--", "."], in: url
        ) else { return [] }
        if data.count > 8 * 1024 * 1024 {
            return [SecretScanner.Finding(path: "", label: "diff too large to scan")]
        }
        return withoutIgnoredSecrets(SecretScanner.findings(inLog: String(decoding: data, as: UTF8.self)))
    }

    /// Push All's pre-flight: which of `repos` have unpushed secret-looking lines. Chunked by 8
    /// concurrent scans — same bounded pattern as `WorkspaceStore.runBulk`/`refreshAll` — so a
    /// 40-repo workspace doesn't scan sequentially before the confirmation can exclude the flagged
    /// ones. Not a pure function (`unpushedSecretFindings` shells out to git per repo), so this is
    /// the async helper `CommandPalette+Actions.performAll` calls rather than a bare `[RepositoryStore]
    /// -> [RepositoryStore]`.
    public static func flaggedForSecrets(in repos: [RepositoryStore]) async -> [RepositoryStore] {
        var flagged: [RepositoryStore] = []
        for start in stride(from: 0, to: repos.count, by: 8) {
            let chunk = repos[start..<min(start + 8, repos.count)]
            let tasks = chunk.map { repo in Task { (repo, await repo.unpushedSecretFindings()) } }
            for task in tasks {
                let (repo, findings) = await task.value
                if !findings.isEmpty { flagged.append(repo) }
            }
        }
        return flagged
    }
}
