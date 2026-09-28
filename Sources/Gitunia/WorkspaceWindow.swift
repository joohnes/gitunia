import SwiftUI
import AppKit
import UserNotifications
import GituniaCore

/// A window's root: resolves (or claims) its workspace store, publishes it as the focused
/// workspace for menu commands, keeps the saved window list current, and guards closing an
/// untitled workspace that has content.
struct WorkspaceWindow: View {
    @Binding var id: UUID?
    var registry: WorkspaceRegistry
    var launch: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(ToastCenter.self) private var toasts
    @Environment(UpdateCoordinator.self) private var updateCoordinator
    @State private var store: WorkspaceStore?
    /// The id this window settled on — held locally because writing the scene's `id` binding may
    /// not read back until SwiftUI next updates the scene.
    @State private var windowID: UUID?

    var body: some View {
        Group {
            if let store, let windowID {
                WindowContent(store: store, windowID: windowID, registry: registry)
                    .focusedSceneValue(\.workspace, store)
                    .focusedSceneValue(\.windowID, windowID)
                    .onChange(of: store.selectedRepoID) { registry.persistWindows() }
                    .onChange(of: store.fileURL) { registry.persistWindows() }
            } else {
                ProgressView()
            }
        }
        // Closing is detected by the guard's `windowWillClose`, not `.onDisappear`, which also fires
        // when a window merely leaves the screen (e.g. a background tab). Installed as soon as the id
        // is known, not once the store has loaded: a window closed mid-load must still be forgotten.
        .background {
            if let windowID { WindowCloseGuard(registry: registry, windowID: windowID, toasts: toasts) }
        }
        // Not `.task(id:)`: claiming an id writes `id`, and restarting would cancel the open mid-refresh.
        .task {
            // A re-run after the view reappears must never re-attach (that would swap in a new store).
            guard store == nil else { return }
            registry.openWindowAction = { openWindow(value: $0) }
            let registry = registry, updates = updateCoordinator
            AppDelegate.onTerminate = { registry.prepareForTermination(); updates.installOnQuitIfPrepared() }
            // Before any attach: a window macOS restored by itself arrives with its saved id and
            // must find its pending file, not become an empty untitled workspace.
            launch.ensurePlan(registry: registry)
            let resolved = id ?? launch.claimFirstWindow(registry: registry)
            if id == nil { id = resolved }
            windowID = resolved
            store = await registry.attachWindow(resolved)
            if let error = registry.takeAttachError(resolved) {
                toasts.post(.error("Couldn't open workspace", detail: error))
            }
            launch.openRemaining(registry: registry, except: resolved)
            updateCoordinator.startIfNeeded()
            for name in launch.notFound {
                toasts.post(.error("Workspace \(name) not found", detail: "It was open when Gitunia quit, but the file is gone."))
            }
            launch.notFound = []
        }
    }
}

/// The per-window body: `ContentView` plus this window's repository sheets.
struct WindowContent: View {
    var store: WorkspaceStore
    var windowID: UUID
    var registry: WorkspaceRegistry
    @Environment(ToastCenter.self) private var toasts
    @State private var repoSheets = RepoSheets()

    var body: some View {
        ContentView(workspace: store, openWorkspace: {
            guard let url = WorkspacePanels.chooseWorkspaceFile() else { return }
            open(url)
        }, newWindow: { registry.newWindow() }, openRecent: open)
        // Reading `settings.accent` here tracks it (Observation), so an accent change re-runs this
        // body and re-tints the whole window; see `Theme.accent(_:)`.
        .tint(Theme.accent(registry.app.settings.accent))
        .onChange(of: registry.app.settings.appearance, initial: true) { _, mode in NSApp.appearance = mode.nsAppearance }
        .onChange(of: registry.app.activity.unseenCount, initial: true) { _, n in NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }
        .modifier(RepoSheetsPresenter(sheets: repoSheets, workspace: store))
        .environment(repoSheets)
        .navigationTitle(store.displayName)
        .focusedSceneValue(\.repoSheets, repoSheets)
    }

    private func open(_ url: URL) {
        Task { await registry.openOrToast(url, from: windowID, toasts: toasts) }
    }
}

extension WorkspaceRegistry {
    /// Open Workspace / Open Recent, from a window or the menu: a failure becomes a toast.
    func openOrToast(_ url: URL, from current: UUID?, toasts: ToastCenter) async {
        do { try await open(url, from: current) }
        catch { toasts.post(.error("Can't open workspace", detail: "\(url.lastPathComponent): \(error.localizedDescription)")) }
    }
}

/// Launch-time bookkeeping: the system opens one window by itself; it adopts the first saved
/// window, and the rest are opened once, after it.
@MainActor
final class LaunchCoordinator {
    private var plan: [WindowState]?
    private var openedRest = false
    var notFound: [String] = []

    /// Runs `launchPlan` once per launch (it also registers each saved window's pending file).
    func ensurePlan(registry: WorkspaceRegistry) {
        guard plan == nil else { return }
        let p = registry.launchPlan()
        plan = p.windows
        notFound = p.notFound
    }

    func claimFirstWindow(registry: WorkspaceRegistry) -> UUID {
        ensurePlan(registry: registry)
        // Skip entries a system-restored window already took.
        while let first = plan?.first, registry.store(for: first.id) != nil { plan?.removeFirst() }
        if let first = plan?.first { plan?.removeFirst(); return first.id }
        return UUID()
    }

    func openRemaining(registry: WorkspaceRegistry, except id: UUID) {
        guard !openedRest else { return }
        openedRest = true
        for w in plan ?? [] where w.id != id && registry.store(for: w.id) == nil { registry.openWindowAction?(w.id) }
        plan = []
    }
}

/// Quitting must not look like closing every window one by one: the registry is told first so the
/// saved window list survives the closes that follow.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onTerminate: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if sender.windows.contains(where: \.isDocumentEdited), !CloseDelegateProxy.confirmDiscardEdits() {
                return .terminateCancel
            }
            AppDelegate.onTerminate?()
            return .terminateNow
        }
    }

    /// Set by `WorkspaceRegistry`: a notification click (`RepoNotifier.userInfo`).
    @MainActor static var onNotificationTap: ((_ repoPath: String, _ hash: String?) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run`/tests have no bundle: UNUserNotificationCenter traps there.
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    /// Parses a notification's userInfo and hands it to `onNotificationTap`; nil when it isn't ours.
    @MainActor @discardableResult
    static func handleNotificationTap(userInfo: [String: String]) -> (repoPath: String, hash: String?)? {
        guard let path = userInfo["repoPath"], !path.isEmpty else { return nil }
        onNotificationTap?(path, userInfo["hash"])
        return (path, userInfo["hash"])
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        Task { @MainActor in AppDelegate.handleNotificationTap(userInfo: info) }
        completionHandler()
    }

    /// Without this, macOS silently drops notifications that arrive while Gitunia is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// SwiftUI has no "should close" hook; this installs a proxy delegate on the hosting window that
/// answers `windowShouldClose` and forwards everything else to SwiftUI's own delegate.
private struct WindowCloseGuard: NSViewRepresentable {
    var registry: WorkspaceRegistry
    var windowID: UUID
    var toasts: ToastCenter

    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        let proxy = context.coordinator
        view.onWindow = { proxy.install(on: $0) }
        return view
    }
    /// Re-wraps if SwiftUI has since replaced the window's delegate.
    func updateNSView(_ nsView: WindowHookView, context: Context) {
        if let window = nsView.window { context.coordinator.install(on: window) }
    }
    static func dismantleNSView(_ nsView: WindowHookView, coordinator: CloseDelegateProxy) {
        coordinator.uninstall(from: nsView.window)
    }
    func makeCoordinator() -> CloseDelegateProxy {
        CloseDelegateProxy(registry: registry, windowID: windowID, toasts: toasts)
    }
}

/// Reports the window it lands in — no async hop needed to find the hosting `NSWindow`.
final class WindowHookView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

@MainActor
final class CloseDelegateProxy: NSObject, NSWindowDelegate {
    let registry: WorkspaceRegistry
    let windowID: UUID
    let toasts: ToastCenter
    // Read from the nonisolated Objective-C forwarding hooks below; only ever touched on the main thread.
    // Strong: `NSWindow.delegate` is weak, so while this proxy sits there nothing else guarantees
    // SwiftUI's controller is reachable through it.
    nonisolated(unsafe) private var original: NSWindowDelegate?
    private var allowClose = false

    init(registry: WorkspaceRegistry, windowID: UUID, toasts: ToastCenter) {
        self.registry = registry; self.windowID = windowID; self.toasts = toasts
    }

    /// The guard view can be recreated while the window lives (it was, twice, at launch), so the
    /// delegate may already be an earlier proxy whose coordinator is about to be freed. Take over the
    /// real SwiftUI delegate it wraps instead of wrapping the wrapper: a chain through a freed proxy
    /// cut SwiftUI off from every window callback, which stopped live resize after a moment.
    func install(on window: NSWindow) {
        // Windows are reopened by id from `workspace.json`, and SwiftUI's own frame autosave is
        // one key per window *type*, so each window's position and size is saved here by its id.
        // Applied again one run-loop turn later: SwiftUI still sizes a window opened by
        // `openWindow` after this, and saving only starts then so that sizing isn't recorded.
        if !frameRestoreStarted {
            frameRestoreStarted = true
            let saved = UserDefaults.standard.string(forKey: frameKey)
            if let saved { window.setFrame(from: saved) }
            DispatchQueue.main.async { [weak self, weak window] in
                if let saved, let window { window.setFrame(from: saved) }
                self?.restoredFrame = true
            }
        }
        guard window.delegate !== self else { return }
        let current = window.delegate
        original = (current as? CloseDelegateProxy)?.original ?? current
        window.delegate = self
    }

    /// Hands the window back to SwiftUI's delegate when this guard's view goes away.
    func uninstall(from window: NSWindow?) {
        guard let window, window.delegate === self else { return }
        window.delegate = original
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }
    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : nil
    }

    private var frameRestoreStarted = false
    private var restoredFrame = false
    private var frameKey: String { "GituniaWindowFrame-\(windowID.uuidString)" }

    private func saveFrame(_ notification: Notification) {
        guard restoredFrame, let window = notification.object as? NSWindow else { return }
        UserDefaults.standard.set(window.frameDescriptor, forKey: frameKey)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame(notification)
        original?.windowDidMove?(notification)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame(notification)
        original?.windowDidResize?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        // A closed window's id never comes back; on quit the frame stays for the next launch.
        if !registry.isTerminating { UserDefaults.standard.removeObject(forKey: frameKey) }
        registry.windowClosed(windowID)
        original?.windowWillClose?(notification)
    }

    /// Unsaved in-place file edits (`EditSession`, surfaced as `NSWindow.isDocumentEdited`): a
    /// modal yes/no, since the session that could save lives inside the SwiftUI tree. Cancel
    /// leaves the window open so the user can press ⌘S.
    static func confirmDiscardEdits() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A file has unsaved changes"
        alert.informativeText = "Closing now discards the edits. Cancel and press ⌘S to keep them."
        alert.addButton(withTitle: "Discard Edits")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose || registry.isTerminating { return original?.windowShouldClose?(sender) ?? true }
        if sender.isDocumentEdited, !Self.confirmDiscardEdits() { return false }
        guard let store = registry.store(for: windowID), store.isUntitled, !store.file.isEmpty else {
            return original?.windowShouldClose?(sender) ?? true
        }
        let alert = NSAlert()
        alert.messageText = "Save this workspace?"
        alert.informativeText = "It has \(Self.count(store.repositories.count + store.missingPaths.count, "repository", "repositories")) and \(Self.count(store.file.folders.count, "linked folder", "linked folders")). If you don't save it, the list is gone — the repositories themselves stay on disk."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if WorkspaceActions.saveAs(store, toasts: self.toasts) { self.allowClose = true; sender.close() }
            case .alertSecondButtonReturn:
                self.registry.discardUntitled(self.windowID)
                self.allowClose = true
                sender.close()
            default: break
            }
        }
        return false
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}
