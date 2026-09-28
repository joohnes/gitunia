import SwiftUI
import GituniaCore

// `ContentView`'s dialogs, each a `ViewModifier` because chaining them directly onto its `body`
// exceeds the type checker's time budget. The state stays in `ContentView`, passed by binding.

/// The Save/Discard/Cancel dialog behind `EditSession.guardNavigation`.
struct UnsavedEditsDialog: ViewModifier {
    var editSession: EditSession

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "This file has unsaved changes",
            isPresented: Binding(get: { editSession.showConfirm }, set: { if !$0 { editSession.cancelNavigation() } }),
            titleVisibility: .visible
        ) {
            Button("Save") { editSession.confirmSave() }
            Button("Discard", role: .destructive) { editSession.confirmDiscard() }
            Button("Cancel", role: .cancel) { editSession.cancelNavigation() }
        } message: {
            Text("Save or discard your edits before leaving this file.")
        }
    }
}

/// `RemoteOpsCoordinator`'s dialogs, hosted by `ContentView` because it is the common ancestor of
/// every call site (sidebar, toolbar, palette).
struct RemoteOpsDialogs: ViewModifier {
    var remoteOps: RemoteOpsCoordinator
    var toasts: ToastCenter
    @State private var newRemoteURL = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Add remote \"origin\"",
                isPresented: Binding(get: { remoteOps.pendingAddRemote != nil }, set: { if !$0 { remoteOps.pendingAddRemote = nil; newRemoteURL = "" } })
            ) {
                TextField("https://github.com/you/repo.git", text: $newRemoteURL)
                Button("Add and Push") {
                    let url = newRemoteURL
                    newRemoteURL = ""
                    if let store = remoteOps.pendingAddRemote {
                        Task { await remoteOps.addOriginAndPush(on: store, url: url, toasts: toasts) }
                    }
                }
                Button("Cancel", role: .cancel) { remoteOps.pendingAddRemote = nil; newRemoteURL = "" }
            } message: {
                Text("\(remoteOps.pendingAddRemote?.repo.name ?? "This repository") has no remote to push to. Paste the repository's URL to add it as origin.")
            }
            .confirmationDialog(
                "This branch has diverged",
                isPresented: Binding(get: { remoteOps.pendingDivergedPull != nil }, set: { if !$0 { remoteOps.pendingDivergedPull = nil } }),
                titleVisibility: .visible
            ) {
                if let store = remoteOps.pendingDivergedPull {
                    Button("Rebase My Commits On Top") {
                        Task { await remoteOps.runRebase(on: store, toasts: toasts) }
                    }
                    Button("Merge") {
                        Task { await remoteOps.runMerge(on: store, toasts: toasts) }
                    }
                }
                Button("Cancel", role: .cancel) { remoteOps.pendingDivergedPull = nil }
            } message: {
                Text("Rebase replays your commits on top of the remote's — history stays linear, but your commits get new hashes. Merge keeps both histories intact and adds a merge commit.")
            }
            .confirmationDialog(
                forcePushTitle,
                isPresented: Binding(get: { remoteOps.pendingForcePush != nil }, set: { if !$0 { remoteOps.pendingForcePush = nil } }),
                titleVisibility: .visible
            ) {
                if let pending = remoteOps.pendingForcePush {
                    Button("Force Push", role: .destructive) {
                        Task { await remoteOps.runForcePush(pending, toasts: toasts) }
                    }
                }
                Button("Cancel", role: .cancel) { remoteOps.pendingForcePush = nil }
            } message: {
                Text(forcePushMessage)
            }
            .sheet(isPresented: Binding(get: { remoteOps.pendingPushSecrets != nil }, set: { if !$0 { remoteOps.pendingPushSecrets = nil } })) {
                if let pending = remoteOps.pendingPushSecrets {
                    PushSecretsSheet(
                        repoName: pending.store.repo.name,
                        findings: pending.findings,
                        onIgnore: { remoteOps.workspace?.ignoreSecretScan($0, for: pending.store) },
                        onPush: {
                            remoteOps.pendingPushSecrets = nil
                            Task { await pending.proceed() }
                        },
                        onCancel: { remoteOps.pendingPushSecrets = nil })
                }
            }
    }

    private var forcePushTitle: String {
        guard let pending = remoteOps.pendingForcePush else { return "Force push?" }
        return "Force push \(pending.branch) in \(pending.store.repo.name)?"
    }

    private var forcePushMessage: String {
        guard let pending = remoteOps.pendingForcePush else { return "" }
        let branch = pending.branch
        let remote = (branch == pending.store.repo.branch ? pending.store.upstreamRemote : nil) ?? "the remote"
        return "This overwrites \(remote)/\(branch) with your local history (--force-with-lease). Commits on \(remote) that aren't in your local branch will be lost."
    }
}

struct CleanPreviewSheetPresenter: ViewModifier {
    @Binding var pendingRepo: RepositoryStore?

    func body(content: Content) -> some View {
        content.sheet(item: $pendingRepo) { repo in
            CleanPreviewSheet(repo: repo)
        }
    }
}

/// The action row's discard-all and undo-last-commit confirmations.
struct ActionRowDialogs: ViewModifier {
    @Binding var showDiscardAllConfirm: Bool
    @Binding var pendingUndo: PendingUndo?
    let discardAllTitle: String
    let onDiscardAll: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(discardAllTitle, isPresented: $showDiscardAllConfirm, titleVisibility: .visible) {
                Button("Discard", role: .destructive, action: onDiscardAll)
            } message: {
                Text("This cannot be undone. Untracked files are left alone.")
            }
            .modifier(UndoCommitDialogs(pending: $pendingUndo))
    }
}
