import SwiftUI
import AppKit
import GituniaCore

/// "Show this commit in History" from anywhere — the Activity window, the cross-repo search sheet,
/// ⌘K's "Go to Commit…". History's selection is `ContentView` state, so this only picks the
/// window, selects the repo there and publishes `pending`; that window's `ContentView` does the
/// actual jump (`consumePendingNavigation`) and clears it.
///
/// Sequencing: selecting a different repo makes `ContentView.restoreSelection` clear
/// `selectedCommit`. `ContentView` only consumes `pending` once `restoreSelection` has run for the
/// target repo (it records `restoredRepoID` there and re-checks `pending` right after), so the
/// clear always lands before the jump — whichever of the two `onChange`s SwiftUI delivers first.
@MainActor
@Observable
final class HistoryNavigator {
    struct Pending: Equatable {
        let repoID: URL
        let hash: String
        let windowID: UUID?
    }

    var pending: Pending?
    @ObservationIgnored weak var registry: WorkspaceRegistry?

    /// False when no open window has the repo — the caller falls back (toast/copy).
    @discardableResult
    func show(commit hash: String, in repo: RepositoryStore, preferWindow: UUID? = nil) -> Bool {
        guard let registry, let (id, ws, target) = registry.window(containing: repo.url.path, prefer: preferWindow) else {
            return false
        }
        ws.select(target)
        if let open = registry.openWindowAction {
            open(id)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        pending = Pending(repoID: target.id, hash: hash, windowID: id)
        return true
    }

    /// The window showing `workspace` — callers pass it as `preferWindow` to stay in their own window.
    func windowID(of workspace: WorkspaceStore) -> UUID? {
        registry?.stores.first { $0.value === workspace }?.key
    }

    /// Whether `pending` is addressed to the window showing `workspace`.
    func targets(_ workspace: WorkspaceStore) -> Bool {
        guard let pending else { return false }
        guard let windowID = pending.windowID else { return workspace.repository(atPath: pending.repoID.path) != nil }
        return registry?.store(for: windowID) === workspace
    }
}

extension WorkspaceRegistry {
    /// The window (preferring `prefer`, else the first in window order) whose workspace has the
    /// repository at `path`.
    // ponytail: window order, not z-order; track key-window order if "frontmost" ever matters.
    func window(containing path: String, prefer: UUID? = nil) -> (UUID, WorkspaceStore, RepositoryStore)? {
        let ids = (prefer.map { [$0] } ?? []) + windowOrder
        for id in ids {
            if let ws = store(for: id), let repo = ws.repository(atPath: path) { return (id, ws, repo) }
        }
        return nil
    }
}
