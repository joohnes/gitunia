import SwiftUI
import GituniaCore

/// What "Restore This Version…" is restoring: this commit's content, or the content immediately
/// before it (`<hash>^`, git's own parent-ref syntax) — the "put it back how it was before the
/// agent" case from the plan. Shared by `CommitDiffView`'s file-list context menu and
/// `HistoryView`'s file-history entries, so both say exactly the same thing and call the same code.
enum RestoreFileTarget: Equatable {
    case thisCommit(CommitInfo)
    case beforeCommit(CommitInfo)

    var sourceRef: String {
        switch self {
        case .thisCommit(let commit): return commit.hash
        case .beforeCommit(let commit): return "\(commit.hash)^"
        }
    }
}

struct PendingRestore: Identifiable, Equatable {
    let path: String
    let target: RestoreFileTarget
    var id: String { "\(path)|\(target.sourceRef)" }
}

@MainActor
enum RestoreFileRunner {
    static func confirmTitle(for pending: PendingRestore) -> String {
        let name = (pending.path as NSString).lastPathComponent
        switch pending.target {
        case .thisCommit(let commit): return "Restore \(name) to \(commit.shortHash)?"
        case .beforeCommit(let commit): return "Restore \(name) to before \(commit.shortHash)?"
        }
    }

    /// `hasUncommittedChanges` — from the pure `RestoreFileConfirmation.hasUncommittedChanges`,
    /// computed by the caller from `repo.repo.changes` — adds the "those are lost" line only when
    /// there's actually something on disk that would be lost.
    static func confirmMessage(for pending: PendingRestore, hasUncommittedChanges: Bool) -> String {
        var message = "The working-tree copy of \(pending.path) is overwritten with its content at that point."
        if hasUncommittedChanges {
            message += " This file has uncommitted changes — those are lost."
        }
        return message
    }

    static func perform(_ pending: PendingRestore, on store: RepositoryStore, toasts: ToastCenter) async {
        guard await store.restoreFile(pending.path, from: pending.target.sourceRef) else { return }
        toasts.post(.success("Restored \((pending.path as NSString).lastPathComponent)", detail: store.repo.name))
    }
}
