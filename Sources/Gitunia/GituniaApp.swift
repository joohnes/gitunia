import SwiftUI
import GituniaCore

@main
struct GituniaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // No default values: they'd run before `init` and build a second registry (a second
    // `AppConfig`, re-running its launch work) that `init` then throws away.
    @State private var registry: WorkspaceRegistry
    @State private var launch = LaunchCoordinator()
    @State private var toasts: ToastCenter
    @State private var editorRequests = EditorOpenCoordinator()
    @State private var remoteOps = RemoteOpsCoordinator()
    @State private var updateCoordinator: UpdateCoordinator

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let registry = WorkspaceRegistry()
        let toasts = ToastCenter()
        _registry = State(initialValue: registry)
        _toasts = State(initialValue: toasts)
        _updateCoordinator = State(initialValue: UpdateCoordinator(app: registry.app, toasts: toasts))
        registry.attach(toasts: toasts)
    }

    var body: some Scene {
        WindowGroup("Gitunia", for: UUID.self) { $id in
            WorkspaceWindow(id: $id, registry: registry, launch: launch)
                // `.environment` only writes into the subtree of the view it modifies, so it must
                // wrap the overlay too — the reverse order leaves ToastOverlay outside the write
                // and it traps on a missing ToastCenter at launch.
                .overlay(alignment: .bottomTrailing) { ToastOverlay() }
                .environment(toasts)
                .environment(editorRequests)
                .environment(remoteOps)
                .environment(registry.navigator)
                .environment(updateCoordinator)
        }
        .commands {
            WorkspaceCommands(registry: registry, toasts: toasts, editorRequests: editorRequests, remoteOps: remoteOps)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updateCoordinator.checkIfDue(force: true) }
            }
        }

        Window("Activity", id: "activity") {
            ActivityWindow(registry: registry)
                .tint(Theme.accent(registry.app.settings.accent))
                .environment(toasts)
        }

        MenuBarExtra {
            MenuBarContent(registry: registry)
                .tint(Theme.accent(registry.app.settings.accent))
                .environment(toasts)
        } label: {
            Label(menuBarLabel, systemImage: "arrow.triangle.branch")
        }

        Settings {
            SettingsView(app: registry.app, updates: updateCoordinator)
                .tint(Theme.accent(registry.app.settings.accent))
        }
    }

    /// Sums every open window. A repo open in two workspaces counts once (deduped by repo id).
    private var menuBarLabel: String {
        let stores = registry.allStores
        let changed = Set(stores.flatMap { $0.changedRepositories.map(\.id) }).count
        let ahead = stores.flatMap(\.repositories)
            .reduce(into: [URL: Int]()) { $0[$1.id] = $1.repo.ahead }
            .values.reduce(0, +)
        let unseen = registry.app.activity.unseenCount
        return (ahead > 0 ? "\(changed) ∙ ↑\(ahead)" : "\(changed)") + (unseen > 0 ? " · \(unseen) new" : "")
    }
}

/// The File-menu workspace commands, acting on whichever window has focus.
private struct WorkspaceCommands: Commands {
    var registry: WorkspaceRegistry
    var toasts: ToastCenter
    var editorRequests: EditorOpenCoordinator
    var remoteOps: RemoteOpsCoordinator
    @FocusedValue(\.workspace) private var focused: WorkspaceStore?
    @FocusedValue(\.windowID) private var windowID: UUID?
    @FocusedValue(\.repoSheets) private var sheets: RepoSheets?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { registry.newWindow() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Button("Open Workspace…") {
                guard let url = WorkspacePanels.chooseWorkspaceFile() else { return }
                open(url)
            }
            .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(registry.app.config.recentWorkspaces, id: \.self) { path in
                    Button(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) {
                        open(URL(fileURLWithPath: path))
                    }
                }
                Divider()
                Button("Clear Menu") { registry.app.clearRecents() }
                    .disabled(registry.app.config.recentWorkspaces.isEmpty)
            }
            Button("Save Workspace As…") {
                guard let focused else { return }
                WorkspaceActions.saveAs(focused, toasts: toasts)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(focused == nil)
            Divider()
            Button("Add Folder to Workspace…") {
                guard let focused else { return }
                WorkspaceActions.addFolder(to: focused, toasts: toasts)
            }
            .disabled(focused == nil)
            Button("Add Repos in Folder…") {
                guard let focused else { return }
                WorkspaceActions.addReposInFolder(to: focused, toasts: toasts)
            }
            .disabled(focused == nil)
            Button("Manage Workspace…") { sheets?.active = .manageWorkspace }
                .disabled(sheets == nil)
            Divider()
            Button("Refresh All") {
                guard let focused else { return }
                Task { await focused.refreshAll() }
            }
            .keyboardShortcut("r")
            .disabled(focused == nil)
            Button("Clone Repository…") { sheets?.active = .clone }
                .disabled(sheets == nil)
            Button("New Repository…") { sheets?.active = .newRepository }
                .disabled(sheets == nil)
            Divider()
            PaletteCommandItem()
            Divider()
            Button("Fetch Selected Repository") {
                guard let repo = selectedRepo else { return }
                Task { await remoteOps.requestFetch(on: repo, toasts: toasts) }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(selectedRepo == nil || selectedRepo!.isBusy)

            Button("Pull Selected Repository") {
                guard let repo = selectedRepo else { return }
                Task { await remoteOps.requestPull(on: repo, toasts: toasts) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(pullDisabled)

            Button("Push Selected Repository") {
                guard let repo = selectedRepo else { return }
                Task { await remoteOps.requestPush(on: repo, toasts: toasts) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(pushDisabled)
            Divider()
            OpenInEditorCommandItem(app: registry.app, editorRequests: editorRequests, toasts: toasts)
        }
        CommandGroup(after: .sidebar) {
            Button("Activity") { openWindow(id: "activity") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Next Changed Repository") { focused?.selectAdjacentChanged(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focused == nil)
            Button("Previous Changed Repository") { focused?.selectAdjacentChanged(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focused == nil)
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Select Repository \(n)") { focused?.selectRepository(atSidebarIndex: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(focused == nil)
            }
        }
    }

    private var selectedRepo: RepositoryStore? { focused?.selectedRepository }

    /// Mirrors the sidebar context menu's Pull disable condition (SidebarView.swift) so the
    /// keyboard shortcut and the row menu agree on when there's nothing to pull.
    private var pullDisabled: Bool {
        guard let repo = selectedRepo else { return true }
        return repo.isBusy || !repo.hasUpstream || repo.repo.behind == 0
    }

    /// Mirrors the sidebar context menu's Push disable condition.
    private var pushDisabled: Bool {
        guard let repo = selectedRepo else { return true }
        return repo.isBusy || (repo.hasUpstream && repo.repo.ahead == 0)
    }

    private func open(_ url: URL) {
        Task { await registry.openOrToast(url, from: windowID, toasts: toasts) }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ToastCenter.self) private var toasts
    var registry: WorkspaceRegistry

    var body: some View {
        let withChanges = registry.windowOrder.compactMap { id in registry.store(for: id).map { (id, $0) } }
            .filter { !$0.1.changedRepositories.isEmpty }
        Group {
            if withChanges.isEmpty {
                Text("No changes").disabled(true)
            } else {
                ForEach(withChanges, id: \.0) { id, store in
                    Section(store.displayName) {
                        ForEach(store.changedRepositories) { repo in
                            Button("\(repo.repo.name)  (\(repo.repo.changeCount))") {
                                store.selectedRepoID = repo.id
                                show(id)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Fetch All") { Task { await runBulk(kind: "Fetched") { await $0.fetchAll() } } }
                .disabled(registry.allStores.contains { $0.bulk != nil })
            Button("Pull All") { Task { await runBulk(kind: "Pulled") { await $0.pullAll() } } }
                .disabled(registry.allStores.contains { $0.bulk != nil })
            Button("Refresh All") { Task { for s in registry.allStores { await s.refreshAll() } } }
            Button("Open Gitunia") { show(registry.windowOrder.first) }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .onAppear(perform: installOpener)
    }

    /// With every window closed nothing else sets the registry's opener, so the menu bar does.
    /// Only fills a missing one — any opener just calls `openWindow(value:)`.
    private func installOpener() {
        guard registry.openWindowAction == nil else { return }
        let openWindow = openWindow
        registry.openWindowAction = { openWindow(value: $0) }
    }

    /// Focuses window `id` (`openWindow(value:)` brings forward a window already showing it), or
    /// opens a new untitled one when there's none.
    private func show(_ id: UUID?) {
        installOpener()
        if let id { registry.openWindowAction?(id) } else { registry.newWindow() }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Runs across every open workspace and posts one combined result toast.
    private func runBulk(kind: String, _ action: (WorkspaceStore) async -> BulkOperation) async {
        var combined: BulkOperation?
        for store in registry.allStores {
            let op = await action(store)
            if var c = combined {
                c.completed += op.completed; c.total += op.total; c.failures += op.failures
                combined = c
            } else { combined = op }
        }
        if let combined { RemoteActionRunner.postBulkResult(combined, kind: kind, toasts: toasts) }
    }
}

/// Reads the focused window's palette-open binding (published by `ContentView` via
/// `.focusedValue(\.paletteOpen, ...)`) so ⌘K opens the palette in whichever window has focus,
/// without a NotificationCenter post or a global singleton. Disabled when no window is focused.
private struct PaletteCommandItem: View {
    @FocusedValue(\.paletteOpen) private var paletteOpen

    var body: some View {
        Button("Command Palette…") { paletteOpen?.wrappedValue = true }
            .keyboardShortcut("k")
            .disabled(paletteOpen == nil)
    }
}

/// ⌘⇧O: opens the file whose selection is on screen — the Changes-mode diff or, since this task,
/// the file selected in History's file list too — read via the same focused-value channel as
/// `PaletteCommandItem` (`ContentView`'s `.focusedValue(\.editorTarget, ...)`). Disabled — not
/// just a no-op — when nothing's selected, since a menu item that fires and does nothing is worse
/// than a greyed-out one. Goes through `EditorOpenCoordinator` like every other call site, so a
/// missing/uninstalled editor prompts instead of silently falling back to the system default, and
/// through `openWorkingTreeFile` so a History file deleted since its commit toasts instead of
/// opening nothing.
private struct OpenInEditorCommandItem: View {
    @FocusedValue(\.editorTarget) private var target
    var app: AppConfig
    var editorRequests: EditorOpenCoordinator
    var toasts: ToastCenter

    var body: some View {
        Button("Open in Editor") {
            guard let target else { return }
            editorRequests.openWorkingTreeFile(
                target.path, in: target.repoURL,
                configuredBundleID: app.settings.editorBundleID, toasts: toasts
            )
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(target == nil)
    }
}
