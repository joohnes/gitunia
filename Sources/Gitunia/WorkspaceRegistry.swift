import SwiftUI
import GituniaCore

/// Every open window's workspace. Owns the one shared `AppConfig` and saves the window list itself
/// (instead of relying on macOS window restoration, which the default "Close windows when quitting
/// an application" setting turns off) so a restart brings back every window as it was.
@MainActor
@Observable
final class WorkspaceRegistry {
    let app: AppConfig
    private(set) var stores: [UUID: WorkspaceStore] = [:]
    private(set) var windowOrder: [UUID] = []
    /// Set from a view's `@Environment(\.openWindow)` — the registry itself can't open windows.
    @ObservationIgnored var openWindowAction: (@MainActor (UUID) -> Void)?
    /// Quitting closes every window; those closes must not empty the saved list.
    var isTerminating = false
    @ObservationIgnored private var pendingFiles: [UUID: URL] = [:]
    @ObservationIgnored private var pendingSelection: [UUID: String] = [:]
    /// Saved windows from the launch plan that haven't attached yet: kept in the saved list so a
    /// quit before they open doesn't drop them.
    @ObservationIgnored private var plannedStates: [UUID: WindowState] = [:]
    /// A saved workspace that exists but failed to open, per window — the window toasts it once.
    @ObservationIgnored private var attachErrors: [UUID: String] = [:]

    @ObservationIgnored private let notifier: RepoNotifier
    /// One per app, injected into every workspace window (`GituniaApp`).
    let navigator = HistoryNavigator()
    /// Set once from `GituniaApp.init()` — the registry is built before the app's `ToastCenter`
    /// `@State` exists, so it can't create its own; `openFromNotification` needs one to report a
    /// repo that isn't open in any workspace (unlike every other toast site, which has a window).
    @ObservationIgnored private(set) var toasts: ToastCenter?

    init(app: AppConfig = AppConfig()) {
        self.app = app
        notifier = RepoNotifier(app: app)
        navigator.registry = self
        AppDelegate.onNotificationTap = { [weak self] in self?.openFromNotification(repoPath: $0, hash: $1) }
    }

    func attach(toasts: ToastCenter) { self.toasts = toasts }

    var allStores: [WorkspaceStore] { windowOrder.compactMap { stores[$0] } }

    func store(for id: UUID) -> WorkspaceStore? { stores[id] }

    /// Launch: migrates, then returns the saved windows to open (in order). Missing files are
    /// skipped and their names returned for a toast.
    func launchPlan() -> (windows: [WindowState], notFound: [String]) {
        app.migrateIfNeeded()
        var ok: [WindowState] = [], notFound: [String] = []
        for w in app.config.windows {
            if FileManager.default.fileExists(atPath: w.workspace) {
                ok.append(w)
                plannedStates[w.id] = w
                if !windowOrder.contains(w.id) { windowOrder.append(w.id) }
                pendingFiles[w.id] = URL(fileURLWithPath: w.workspace)
                if let sel = w.selectedRepo { pendingSelection[w.id] = sel }
            } else {
                notFound.append(URL(fileURLWithPath: w.workspace).deletingPathExtension().lastPathComponent)
            }
        }
        return (ok, notFound)
    }

    /// Idempotent: a window's root view calls this on appear; the store is created once per id.
    func attachWindow(_ id: UUID) async -> WorkspaceStore {
        if let existing = stores[id] { return existing }
        let store = WorkspaceStore(app: app)
        store.onRepoEvents = { [notifier] repo, events in notifier.post(events, repo: repo) }
        stores[id] = store
        plannedStates[id] = nil
        if !windowOrder.contains(id) { windowOrder.append(id) }
        var opened = false
        if let url = pendingFiles.removeValue(forKey: id) {
            do {
                try await store.open(fileURL: url)
                opened = true
                if let sel = pendingSelection.removeValue(forKey: id), let repo = store.repository(atPath: sel) {
                    store.selectedRepoID = repo.id
                }
            } catch {
                attachErrors[id] = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if !opened { await store.openUntitled() }
        // Closed while loading: `windowClosed` already forgot it, but the open above started
        // watching and auto-fetch after that — stop them again and drop the file it created.
        guard stores[id] === store else {
            store.stopWatching()
            if store.isUntitled, store.file.isEmpty, let url = store.fileURL { try? FileManager.default.removeItem(at: url) }
            persistWindows()
            return store
        }
        persistWindows()
        return store
    }

    /// Why this window's saved workspace couldn't be opened, if it couldn't — returned once.
    func takeAttachError(_ id: UUID) -> String? { attachErrors.removeValue(forKey: id) }

    func newWindow() {
        let id = UUID()
        windowOrder.append(id)
        openWindowAction?(id)
    }

    /// Focuses the window that already has `fileURL`, else reuses `current` if it's an empty
    /// untitled workspace, else opens a new window.
    func open(_ fileURL: URL, from current: UUID?) async throws {
        let target = fileURL.standardizedFileURL
        if let (id, _) = stores.first(where: { $0.value.fileURL == target }) {
            openWindowAction?(id)
            return
        }
        _ = try WorkspaceFile.load(from: target)   // fail before creating a window for an unreadable file
        if let current, let store = stores[current], store.isUntitled, store.file.isEmpty {
            let untitled = store.fileURL
            try await store.open(fileURL: target)
            if let untitled { try? FileManager.default.removeItem(at: untitled) }
            persistWindows()
            return
        }
        let id = UUID()
        pendingFiles[id] = target
        windowOrder.append(id)
        _ = await attachWindow(id)
        openWindowAction?(id)
    }

    /// Ignored while terminating; deletes an emptied untitled file.
    func windowClosed(_ id: UUID) {
        guard !isTerminating, let store = stores[id] else { return }
        store.stopWatching()
        if store.isUntitled, store.file.isEmpty, let url = store.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        forget(id)
    }

    /// "Don't Save" on an untitled workspace with content.
    func discardUntitled(_ id: UUID) {
        guard let store = stores[id], store.isUntitled, let url = store.fileURL else { return }
        store.stopWatching()
        try? FileManager.default.removeItem(at: url)
        forget(id)
    }

    private func forget(_ id: UUID) {
        stores[id] = nil
        windowOrder.removeAll { $0 == id }
        persistWindows()
    }

    func persistWindows() {
        app.setWindows(windowOrder.compactMap { id in
            guard let store = stores[id] else { return plannedStates[id] }
            guard let url = store.fileURL else { return nil }
            return WindowState(id: id, workspace: url.path, selectedRepo: store.selectedRepoID?.path)
        })
    }

    /// Flush every store before the process exits; the saved window list stays as it is.
    func prepareForTermination() {
        persistWindows()
        isTerminating = true
        for store in stores.values { store.stopWatching() }
    }
}

extension FocusedValues {
    @Entry var workspace: WorkspaceStore?
    @Entry var windowID: UUID?
    @Entry var repoSheets: RepoSheets?
}
