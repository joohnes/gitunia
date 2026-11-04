import GituniaCore

/// The checks every commit goes through, whether from the commit box or All Changes: stage
/// everything when nothing is staged, then scan what is about to be committed.
@MainActor
enum CommitGate {
    struct Report {
        /// One line per finding; secrets carry only path + label, never the matched value.
        var findings: [String] = []
        /// A finding is a blocker (no git identity): committing is not offered at all.
        var blocked = false
        /// First large file's `git lfs track` pattern and path, set only when `git lfs` is installed.
        var lfsSuggestion: (pattern: String, path: String)?
    }

    /// Nothing staged → stage everything, so the scan sees what will be committed. Per-file when
    /// conflicts exist: `git add -A` would mark them resolved. False when still nothing is staged.
    static func stageIfNothingStaged(_ repo: RepositoryStore) async -> Bool {
        guard repo.stagedChanges.isEmpty else { return true }
        if repo.conflictedChanges.isEmpty {
            await repo.stageAll()
        } else {
            await repo.stage(repo.unstagedChanges + repo.untrackedChanges)
        }
        return !repo.stagedChanges.isEmpty
    }

    /// Scans the added lines of the staged diff for anything secret-shaped and the staged files
    /// for anything over the large-file threshold, and re-reads the identity (one cheap
    /// `git config` call) so a fixed or broken config is seen here, not just on selection. The
    /// signing note is left out — the commit box's caption already shows it.
    static func scan(_ repo: RepositoryStore, amending: Bool) async -> Report {
        // Independent git calls — run together, not one after another.
        async let identityRefreshed: Void = repo.refreshIdentity()
        async let stagedDiff = repo.stagedDiff()
        async let headPatch = amending ? repo.headPatch() : ""
        async let lfsCheck = repo.checkLFSInstalled()
        await identityRefreshed
        let identityIssues = Preflight.identityWarnings(repo.identity).filter { $0.id != "signing" }
        var secrets = repo.withoutIgnoredSecrets(SecretScanner.findings(inDiff: await stagedDiff))
        // Nothing staged (e.g. amending only the message) skips the diff scan above — HEAD's
        // own patch is scanned too so a secret already in the commit still gets caught.
        for finding in repo.withoutIgnoredSecrets(SecretScanner.findings(inLog: await headPatch)) where !secrets.contains(finding) {
            secrets.append(finding)
        }
        let lfsInstalled = await lfsCheck
        let large = Preflight.largeFileWarnings(in: repo.repo.changes, rules: repo.attributeRules, lfsInstalled: lfsInstalled)
        var report = Report()
        report.findings = identityIssues.map(\.message) + secrets.map { "\($0.path): \($0.label)" } + large.map(\.message)
        // ponytail: one Track button for the first large file; the rescan surfaces the next one.
        report.lfsSuggestion = lfsInstalled ? large.first.flatMap { issue in
            issue.suggestedLFSPattern.map { ($0, String(issue.id.dropFirst("large-file:".count))) }
        } : nil
        report.blocked = identityIssues.contains { $0.severity == .blocker }
        return report
    }
}
