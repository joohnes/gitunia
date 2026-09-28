import Foundation

/// `git bisect` start/mark/reset. `operation == .bisect` comes from `BISECT_LOG` (see
/// `refreshOperationState`); `bisect` is refreshed by `refreshStatus()` only while that holds.
extension RepositoryStore {
    public func bisectStart(bad: String, good: String) async -> GitError? {
        let args = ["bisect", "start", bad, good]
        if repo.hasChanges {
            return GitError(args: args, exitCode: -1, stderr: "Your working tree has uncommitted changes — commit or stash them before starting a bisect.")
        }
        if let op = operation {
            return GitError(args: args, exitCode: -1, stderr: "A \(op.label) is in progress — finish or abort it before starting a bisect.")
        }
        // `git bisect start` has no `--end-of-options`; a leading "-" would be read as an option.
        if [bad, good].contains(where: { $0.isEmpty || $0.hasPrefix("-") }) {
            return GitError(args: args, exitCode: -1, stderr: "Enter a commit, tag or branch for both Bad and Good.")
        }
        return await runBisect(["start", bad, good])
    }

    /// `hash`, when given, marks a commit other than the one currently under test (History's
    /// context menu offers this on any commit while bisecting, not just the tested one) — plain
    /// `git bisect good|bad [<hash>]`.
    public func bisectMark(_ verdict: BisectVerdict, hash: String? = nil) async -> GitError? {
        await runBisect(hash.map { [verdict.rawValue, $0] } ?? [verdict.rawValue])
    }

    public func bisectReset() async -> GitError? {
        await runBisect(["reset"])
    }

    public func refreshBisect() async {
        guard let gitDir = gitDirURL(), FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("BISECT_LOG").path),
              let log = try? await git.run(["bisect", "log"], in: url)
        else {
            bisect = nil
            bisectLastOutput = ""
            return
        }
        var state = BisectLog.parse(log: log, lastOutput: bisectLastOutput)
        // Started outside the app (no output seen): HEAD is the commit under test.
        if state.current == nil, state.firstBad == nil { state.current = repo.headOID }
        bisect = state
    }

    private func runBisect(_ args: [String]) async -> GitError? {
        lastError = nil
        beginBusy()
        defer { endBusy() }
        // Stdout is stored before the refresh: `refreshBisect` reads "Bisecting: N left" from it.
        return await attempt(["bisect"] + args, recordError: true) {
            bisectLastOutput = try await git.run(["bisect"] + args, in: url)
        }
    }
}

// MARK: - B7(b): bisect-specific wording for the two spots that otherwise reuse generic
// merge/rebase copy (`ChangesView`'s abort confirmation, `CommitBox`'s "can't commit" message) —
// those files belong to other agents, so the wording lives here as a computed property on
extension GitOperation {
    /// Title for the confirmation before stopping this operation. Bisect's "Reset" returns you to
    /// the branch you started from — framing it as "Abort" (which reads as discarding
    /// in-progress work, true for merge/rebase/cherry-pick/revert) is misleading.
    public func stopConfirmTitle(branch: String) -> String {
        self == .bisect ? "Stop bisecting and return to \(branch)?" : "Abort the \(label)?"
    }

    /// `CommitBox`'s message in place of the commit form while this operation is in progress.
    public var commitBoxMessage: String {
        self == .bisect
            ? "Bisect in progress — mark commits Good or Bad in History"
            : "A \(label) is in progress — use the banner above to Continue, Skip, or Abort it before committing."
    }
}
