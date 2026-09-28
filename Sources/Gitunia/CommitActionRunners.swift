import SwiftUI
import GituniaCore

// MARK: - Undo last commit

/// An "undo commit" awaiting confirmation. `commit` is the HEAD the user was looking at when the
/// call site knows it (History's row menu); nil means "whatever HEAD is at confirm time" (⌘K, the
/// action row). `overrideIssues` non-nil selects the destructive "Proceed anyway?" dialog.
struct PendingUndo {
    let store: RepositoryStore
    var commit: CommitInfo?
    var overrideIssues: [PreflightIssue]?
}

/// "Undo last commit" (`git reset --soft HEAD~1`): wording and the git call, shared by History,
/// the action row and the palette.
@MainActor
enum UndoCommitRunner {
    static let confirmTitle = "Undo this commit?"
    static let confirmMessage = "The commit disappears and its changes return to the index as staged changes, ready to commit again. Nothing is lost — `git reflog` recovers it if needed."

    static func issues(for store: RepositoryStore) -> [PreflightIssue] {
        Preflight.check(.undoLastCommit(hasParent: store.hasParentCommit), repo: store.repo, hasUpstream: store.hasUpstream)
    }

    /// `title` is captured by the caller before the reset — afterwards `lastCommitSummary` names
    /// the now-previous commit. `expectedHead` is the hash the user confirmed when known (nil =
    /// whatever HEAD is now). A refusal lands in `lastError`, toasted by `ContentView`'s watcher.
    static func perform(title: String, expectedHead: String? = nil, on store: RepositoryStore, toasts: ToastCenter) async {
        guard await store.undoLastCommit(expectedHead: expectedHead) else { return }
        let count = store.stagedChanges.count
        toasts.post(.success("Undid \(title)", detail: "\(count) file\(count == 1 ? "" : "s") staged"))
    }

    /// A structural blocker (no parent commit) toasts and returns nil — there's nothing to
    /// override. A pushed-commit blocker gets the destructive override; otherwise the plain
    /// confirmation a soft reset deserves.
    static func request(on store: RepositoryStore, commit: CommitInfo? = nil, toasts: ToastCenter) -> PendingUndo? {
        let found = issues(for: store)
        if let structural = found.first(where: { $0.severity == .blocker && $0.id == "no-parent" }) {
            toasts.post(.error(store.repo.name, detail: structural.message))
            return nil
        }
        let overridable = found.filter { $0.severity == .blocker }
        return PendingUndo(store: store, commit: commit, overrideIssues: overridable.isEmpty ? nil : overridable)
    }

    /// The subject is captured before the reset: afterwards `lastCommitSummary` names the
    /// now-previous commit.
    static func perform(_ pending: PendingUndo, toasts: ToastCenter) {
        let title = pending.commit?.subject ?? pending.store.repo.lastCommitSummary ?? "commit"
        Task { await perform(title: title, expectedHead: pending.commit?.hash, on: pending.store, toasts: toasts) }
    }
}

/// The plain confirmation and the pushed-commit override for `PendingUndo`. `onConfirm` runs
/// alongside the undo (the palette closes itself there).
struct UndoCommitDialogs: ViewModifier {
    @Binding var pending: PendingUndo?
    var onConfirm: () -> Void = {}
    @Environment(ToastCenter.self) private var toasts

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                UndoCommitRunner.confirmTitle,
                isPresented: Binding(get: { pending != nil && pending?.overrideIssues == nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button("Undo Commit", action: confirm)
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(UndoCommitRunner.confirmMessage)
            }
            .confirmationDialog(
                "Proceed anyway?",
                isPresented: Binding(get: { pending?.overrideIssues != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button("Do it anyway", role: .destructive, action: confirm)
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text((pending?.overrideIssues?.map(\.message) ?? []).joined(separator: "\n"))
            }
    }

    private func confirm() {
        let confirmed = pending
        pending = nil
        onConfirm()
        if let confirmed { UndoCommitRunner.perform(confirmed, toasts: toasts) }
    }
}

// MARK: - Revert / cherry-pick

/// One place for the revert confirmation wording and the git call, used by History's context
/// menu and the ⌘K palette.
@MainActor
enum RevertRunner {
    static func confirmTitle(for commit: CommitInfo) -> String { "Revert \"\(commit.subject)\"?" }

    static func confirmMessage(for commit: CommitInfo) -> String {
        let base = "Creates a new commit that undoes this one — nothing is deleted from history, so this is safe even if the commit has already been pushed."
        guard commit.parentCount > 1 else { return base }
        return base + " This is a merge commit: it's reverted relative to its first parent (-m 1), undoing the whole merge."
    }

    static func perform(_ commit: CommitInfo, on store: RepositoryStore, toasts: ToastCenter) async {
        let mainline = commit.parentCount > 1 ? 1 : nil
        guard await store.revertCommit(commit.hash, mainline: mainline) else { return }
        toasts.post(.success("Reverted \(commit.subject)"))
    }
}

@MainActor
enum CherryPickRunner {
    static func confirmTitle(for commit: CommitInfo, currentBranch: String) -> String {
        "Cherry-pick onto \(currentBranch)?"
    }

    static func confirmMessage(for commit: CommitInfo, currentBranch: String) -> String {
        "Applies \"\(commit.subject)\" as a new commit on \(currentBranch)."
    }

    static func perform(_ commit: CommitInfo, on store: RepositoryStore, toasts: ToastCenter) async {
        guard await store.cherryPick(commit.hash) else { return }
        toasts.post(.success("Cherry-picked \(commit.subject)"))
    }
}

/// Revert and cherry-pick confirmations against `repo`. `onConfirm` runs alongside the git call.
struct CommitPickDialogs: ViewModifier {
    @Binding var pendingRevert: CommitInfo?
    @Binding var pendingCherryPick: CommitInfo?
    var repo: RepositoryStore?
    var onConfirm: () -> Void = {}
    @Environment(ToastCenter.self) private var toasts

    private var currentBranch: String { repo?.repo.branch ?? "current" }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingRevert.map(RevertRunner.confirmTitle) ?? "Revert commit?",
                isPresented: Binding(get: { pendingRevert != nil }, set: { if !$0 { pendingRevert = nil } }),
                titleVisibility: .visible
            ) {
                Button("Revert Commit") {
                    onConfirm()
                    if let commit = pendingRevert, let repo { Task { await RevertRunner.perform(commit, on: repo, toasts: toasts) } }
                    pendingRevert = nil
                }
                Button("Cancel", role: .cancel) { pendingRevert = nil }
            } message: {
                Text(pendingRevert.map(RevertRunner.confirmMessage) ?? "")
            }
            .confirmationDialog(
                pendingCherryPick.map { CherryPickRunner.confirmTitle(for: $0, currentBranch: currentBranch) } ?? "Cherry-pick commit?",
                isPresented: Binding(get: { pendingCherryPick != nil }, set: { if !$0 { pendingCherryPick = nil } }),
                titleVisibility: .visible
            ) {
                Button("Cherry-pick") {
                    onConfirm()
                    if let commit = pendingCherryPick, let repo { Task { await CherryPickRunner.perform(commit, on: repo, toasts: toasts) } }
                    pendingCherryPick = nil
                }
                Button("Cancel", role: .cancel) { pendingCherryPick = nil }
            } message: {
                Text(pendingCherryPick.map { CherryPickRunner.confirmMessage(for: $0, currentBranch: currentBranch) } ?? "")
            }
    }
}

// MARK: - Merge

@MainActor
enum MergeRunner {
    /// Preflight (uncommitted changes / an operation in progress) toasts and stops; otherwise
    /// `git merge --no-edit`. Failures, including "stopped on conflicts", reach the user through
    /// `ContentView`'s `lastError` watcher and the operation banner, so only success toasts here.
    static func run(branch: String, on store: RepositoryStore, toasts: ToastCenter) {
        let issues = Preflight.check(.mergeBranch(branch: branch), repo: store.repo, hasUpstream: store.hasUpstream, operationInProgress: store.operation != nil)
        if let blocker = issues.first(where: { $0.severity == .blocker }) {
            toasts.post(.error(store.repo.name, detail: blocker.message))
            return
        }
        Task {
            let result = await store.mergeBranch(branch)
            if result.succeeded {
                toasts.post(.success(result.wasFastForward ? "Fast-forwarded to \(branch)" : "Merged \(branch)", detail: store.repo.name))
            }
        }
    }
}

// MARK: - Branch verbs (rename / delete / delete on remote)

/// A branch verb awaiting its dialog. `delete`'s `forceRetry` is the second step, shown after a
/// real "not fully merged" refusal; `refusalMessage` is git's own stderr for it.
enum PendingBranchVerb {
    case rename(branch: String)
    case delete(branch: String, forceRetry: Bool, refusalMessage: String?)
    case remoteDelete(remote: String, branch: String)
}

/// Rename alert, delete (plain / force) and delete-on-remote confirmations, run against `repo`.
struct BranchVerbDialogs: ViewModifier {
    @Binding var pending: PendingBranchVerb?
    var repo: RepositoryStore?
    @State private var newName = ""
    @Environment(ToastCenter.self) private var toasts

    static func deleteTitle(branch: String, force: Bool) -> String {
        force ? "Force-delete \"\(branch)\"?" : "Delete branch \"\(branch)\"?"
    }

    static let deleteMessage = "This can't be undone if the branch has commits nowhere else, though git refuses if it isn't fully merged."

    private var renaming: String? {
        if case .rename(let branch) = pending { return branch }
        return nil
    }

    private var deleting: (branch: String, forceRetry: Bool, refusalMessage: String?)? {
        if case .delete(let branch, let forceRetry, let refusalMessage) = pending { return (branch, forceRetry, refusalMessage) }
        return nil
    }

    private var remoteDeleting: (remote: String, branch: String)? {
        if case .remoteDelete(let remote, let branch) = pending { return (remote, branch) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename branch",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { pending = nil; newName = "" } })
            ) {
                TextField("New name", text: $newName)
                Button("Rename", action: confirmRename)
                Button("Cancel", role: .cancel) { pending = nil; newName = "" }
            } message: {
                Text("Renames \"\(renaming ?? "")\". If it has an upstream, the branch on the remote keeps its old name — renaming there is a separate push.")
            }
            .confirmationDialog(Self.deleteTitle(branch: deleting?.branch ?? "", force: deleting?.forceRetry == true),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if deleting?.forceRetry == true {
                    Button("Force Delete", role: .destructive, action: confirmDelete)
                } else {
                    Button("Delete", role: .destructive, action: confirmDelete)
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                if deleting?.forceRetry == true {
                    Text("Git refused: \(deleting?.refusalMessage ?? "not fully merged"). Commits unique to this branch become unreachable — recoverable only via `git reflog`.")
                } else {
                    Text(Self.deleteMessage)
                }
            }
            .confirmationDialog("Delete \"\(remoteDeleting?.branch ?? "")\" on \(remoteDeleting?.remote ?? "the remote")?",
                                isPresented: Binding(get: { remoteDeleting != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Delete on Remote", role: .destructive, action: confirmDeleteRemote)
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text("This removes the branch from \(remoteDeleting?.remote ?? "the remote") — it affects everyone using that remote, not just this copy.")
            }
    }

    private func confirmRename() {
        guard let branch = renaming, let repo else { return }
        let newName = newName
        pending = nil
        self.newName = ""
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch await repo.renameBranch(branch, to: newName) {
            case .succeeded(let keptOldRemoteName):
                var detail = "Renamed to \(trimmed)"
                if keptOldRemoteName { detail += " — the remote branch still has the old name" }
                toasts.post(.success(repo.repo.name, detail: detail))
            case .invalidName(let reason):
                toasts.post(.error(repo.repo.name, detail: reason))
            case .duplicateName:
                toasts.post(.error(repo.repo.name, detail: "A branch named \"\(trimmed)\" already exists"))
            case .failed:
                // Already toasted by `ContentView`'s `lastError` watcher.
                break
            }
        }
    }

    /// A real "not fully merged" refusal on the first step re-opens this dialog in `forceRetry`
    /// mode (quoting git's refusal) instead of toasting; other failures go to the `lastError` watcher.
    private func confirmDelete() {
        guard let (branch, forceRetry, _) = deleting, let repo else { return }
        pending = nil
        Task {
            let result = await repo.deleteBranch(branch, force: forceRetry)
            if result.succeeded {
                toasts.post(.success(repo.repo.name, detail: "Deleted \(branch)"))
            } else if result.notFullyMerged, !forceRetry {
                // Cleared before any view update (set after `deleteBranch`'s last await), so the
                // watcher never toasts it alongside the force dialog.
                repo.lastError = nil
                pending = .delete(branch: branch, forceRetry: true,
                                  refusalMessage: result.error?.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func confirmDeleteRemote() {
        guard let (remote, branch) = remoteDeleting, let repo else { return }
        pending = nil
        Task {
            let ok = await repo.deleteRemoteBranch(branch, remote: remote)
            if ok {
                toasts.post(.success(repo.repo.name, detail: "Deleted \(remote)/\(branch) on the remote"))
            } else if let error = repo.lastError {
                toasts.post(.error(repo.repo.name, detail: error.errorDescription, stderr: error.stderr, command: error.commandLine))
                repo.lastError = nil
            }
        }
    }
}
