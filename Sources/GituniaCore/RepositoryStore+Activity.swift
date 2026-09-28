import Foundation

/// Remote activity tracking: diff the remote-tracking refs before/after each fetch. Local git only,
/// plus at most one `gh pr list` when a merged pull request needs its title.
extension RepositoryStore {
    /// The baseline, unless a fetch already recorded one.
    public func takeInitialRemoteSnapshot() async {
        guard remoteSnapshot == nil, let refs = await readRemoteRefs(), remoteSnapshot == nil else { return }
        remoteSnapshot = RemoteRefSnapshot(refs: refs)
    }

    /// nil when git failed — distinct from "no remote branches", so a failed read never reports
    /// every branch as deleted.
    private func readRemoteRefs() async -> [String: String]? {
        guard let out = try? await git.run(["for-each-ref", "--format=%(refname:lstrip=2) %(objectname)", "refs/remotes"], in: url)
        else { return nil }
        return RemoteActivity.parseRefs(out)
    }

    /// `"origin/main"` — `defaultBaseBranch()` answers either `main` or `origin/main`.
    func remoteBaseRef() async -> String? {
        guard let base = await defaultBaseBranch() else { return nil }
        return base.hasPrefix("origin/") ? base : "origin/\(base)"
    }

    /// Diffs a fresh snapshot against `remoteSnapshot` and stores the fresh one. The first call
    /// only records the baseline and returns [].
    public func recordRemoteActivity(after fetchSucceeded: Bool) async -> [ActivityEvent] {
        guard fetchSucceeded, let refs = await readRemoteRefs() else { return [] }
        let new = RemoteRefSnapshot(refs: refs)
        guard let old = remoteSnapshot else { remoteSnapshot = new; return [] }
        remoteSnapshot = new
        let changes = RemoteActivity.diff(old: old, new: new, baseRef: await remoteBaseRef())
        guard !changes.isEmpty else { return [] }

        let path = url.standardizedFileURL.path, name = repo.name
        var events: [ActivityEvent] = []
        var merged: [ActivityEvent] = []
        for change in changes {
            var kind = change.kind
            var commits: [ActivityCommit] = []
            if let newOID = change.newOID {
                var range = ["\(change.oldOID ?? "")..\(newOID)"]
                if change.oldOID == nil {
                    // Only what no other remote branch already has — not the branch's whole history.
                    let short = change.ref.split(separator: "/", maxSplits: 1).last.map(String.init) ?? change.ref
                    range = [newOID, "--not", "--exclude=\(change.ref)", "--exclude=\(short)", "--remotes"]
                } else if let oldOID = change.oldOID,
                          (try? await git.run(["merge-base", "--is-ancestor", oldOID, newOID], in: url)) == nil {
                    kind = .forcePushed
                }
                let log = (try? await git.run(["log", "-n", "50", "--format=\(RemoteActivity.logFormat)"] + range, in: url)) ?? ""
                commits = RemoteActivity.parseCommits(log)
            }
            events.append(ActivityEvent(repoPath: path, repoName: name, kind: kind, ref: change.ref,
                                        oldOID: change.oldOID, newOID: change.newOID, commits: commits))
            guard kind == .baseAdvanced else { continue }
            for commit in commits {
                guard let number = RemoteActivity.pullRequestNumber(inSubject: commit.subject) else { continue }
                merged.append(ActivityEvent(repoPath: path, repoName: name, kind: .pullRequestMerged, ref: change.ref,
                                            oldOID: nil, newOID: commit.hash, commits: [commit], pullRequestNumber: number,
                                            pullRequestTitle: RemoteActivity.squashTitle(commit.subject)))
            }
        }
        return events + (await withPullRequestTitles(merged))
    }

    /// Fills titles from one `gh pr list` call; returns the input unchanged when gh can't help.
    private func withPullRequestTitles(_ merged: [ActivityEvent]) async -> [ActivityEvent] {
        struct Listed: Decodable { let number: Int; let title: String }
        guard !merged.isEmpty, gh.isAvailable, await checkGitHubRemote(),
              let out = try? await gh.run(["pr", "list", "--state", "merged", "--limit", "20", "--json", "number,title,mergedAt"], in: url),
              let listed = try? JSONDecoder().decode([Listed].self, from: Data(out.utf8))
        else { return merged }
        let titles = Dictionary(listed.map { ($0.number, $0.title) }, uniquingKeysWith: { a, _ in a })
        return merged.map { e in
            guard let title = e.pullRequestNumber.flatMap({ titles[$0] }) else { return e }
            return ActivityEvent(id: e.id, repoPath: e.repoPath, repoName: e.repoName, kind: e.kind, ref: e.ref,
                                 oldOID: e.oldOID, newOID: e.newOID, commits: e.commits, pullRequestNumber: e.pullRequestNumber,
                                 pullRequestTitle: title, date: e.date, seen: e.seen)
        }
    }

    /// Remote branches, most recently committed first, for the stale-branches view. Two cheap local
    /// git calls; on demand only, never from `refreshStatus()`.
    public func remoteBranchAges() async -> [(ref: String, lastCommit: Date, author: String, mergedIntoBase: Bool)] {
        let out = (try? await git.run(["for-each-ref", "--sort=-committerdate",
                                       "--format=%(refname:lstrip=2)%1f%(committerdate:iso-strict)%1f%(authorname)",
                                       "refs/remotes"], in: url)) ?? ""
        var merged = Set<String>()
        if let base = await remoteBaseRef(), let list = try? await git.run(["branch", "-r", "--merged", base], in: url) {
            merged = Set(list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.contains(" -> ") })
        }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, f[0].contains("/"), !f[0].hasSuffix("/HEAD") else { return nil }
            return (f[0], RelativeDate.parseISO(f[1]) ?? .distantPast, f[2], merged.contains(f[0]))
        }
    }
}
