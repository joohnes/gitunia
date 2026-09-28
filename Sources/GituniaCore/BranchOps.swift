import Foundation

/// Result of `RepositoryStore.mergeBranch` — same shape philosophy as `RemoteResult`: a plain
/// success/failure flag plus enough classification for the UI to word its toast without
/// re-parsing git output itself.
public struct MergeResult: Sendable {
    public let succeeded: Bool
    /// True when git resolved the merge as a fast-forward (no merge commit created) — parsed from
    /// git's own "Fast-forward" line in `merge`'s output. Meaningless when `succeeded` is false.
    public let wasFastForward: Bool
    public let error: GitError?

    public init(succeeded: Bool, wasFastForward: Bool, error: GitError? = nil) {
        self.succeeded = succeeded; self.wasFastForward = wasFastForward; self.error = error
    }
}

/// Result of `RepositoryStore.renameBranch`. Validation happens before ever calling git, so the
/// caller can show a specific reason instead of git's own `check-ref-format` error text.
public enum RenameOutcome: Sendable, Equatable {
    /// `keptOldRemoteName` is true when the branch had an upstream — renaming a local branch never
    /// renames the branch on the remote (that's a separate push), so the caller should say so.
    case succeeded(keptOldRemoteName: Bool)
    case invalidName(String)
    case duplicateName
    case failed(GitError)

    public static func == (lhs: RenameOutcome, rhs: RenameOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.succeeded(let a), .succeeded(let b)): return a == b
        case (.invalidName(let a), .invalidName(let b)): return a == b
        case (.duplicateName, .duplicateName): return true
        case (.failed(let a), .failed(let b)): return a.stderr == b.stderr
        default: return false
        }
    }
}

/// Result of `RepositoryStore.deleteBranch`. `notFullyMerged` is set when git's real stderr says
/// so — verified in `BranchOpsTests` against a real "not fully merged" repo — so the caller can
/// offer the force-delete (`-D`) confirmation without re-guessing git's wording.
public struct BranchDeleteResult: Sendable {
    public let succeeded: Bool
    public let notFullyMerged: Bool
    public let error: GitError?

    public init(succeeded: Bool, notFullyMerged: Bool, error: GitError? = nil) {
        self.succeeded = succeeded; self.notFullyMerged = notFullyMerged; self.error = error
    }
}
