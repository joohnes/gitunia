import SwiftUI
import GituniaCore

enum ContentMode: String, CaseIterable { case changes = "Changes", history = "History", compare = "Compare" }

struct ContentView: View {
    var workspace: WorkspaceStore
    var openWorkspace: () -> Void = {}
    var newWindow: () -> Void = {}
    var openRecent: (URL) -> Void = { _ in }
    @Environment(ToastCenter.self) private var toasts
    @Environment(EditorOpenCoordinator.self) private var editorRequests
    @Environment(RemoteOpsCoordinator.self) private var remoteOps
    /// Optional: render tests build `ContentView` without it.
    @Environment(HistoryNavigator.self) private var navigator: HistoryNavigator?
    /// The repo `restoreSelection` last ran for — gates `consumePendingNavigation` (see `HistoryNavigator`).
    @State private var restoredRepoID: URL?
    /// ⌘K "Go to Commit…": the repo whose ref prompt is up, and the typed ref.
    @State private var goToCommitRepo: RepositoryStore?
    @State private var goToCommitRef = ""
    @State private var selectedChange: FileChange?
    @State private var selectedCommit: CommitInfo?
    // History's counterpart to `selectedChange` (`CommitDiffView`'s file list), for ⌘⇧O.
    @State private var selectedHistoryFilePath: String?
    @State private var contentMode: ContentMode = .changes
    // ⌘K's "Search History…": switches to History and asks HistoryView's filter field to focus
    // (see `requestHistorySearch` and `HistoryView.focusFilterRequested`).
    @State private var focusHistoryFilter = false
    // Non-nil switches History into file-history mode for that path (`requestFileHistory`).
    // `fileHistorySelectedPath` is HistoryView's readback of the path the selected commit had, so
    // CommitDiffView can preselect the right file.
    @State private var fileHistoryPath: String?
    @State private var fileHistorySelectedPath: String?
    // Shared by `CompareView` (content column) and `CompareDiffView` (detail column). `nil` base
    // means "not resolved yet"; `nil` head means "the current branch".
    @State private var compareBase: String?
    @State private var compareHead: String?
    @State private var compareSelectedPath: String?
    // Asks `DiffView` to turn its own Blame toggle on (see `DiffView.activateBlameRequested`).
    @State private var activateBlameRequested = false
    @State private var showNewBranch = false
    @State private var newBranchName = ""
    // A `ToolbarContent` can't host a `.confirmationDialog` or `.alert`, so the toolbar's dialog
    // state lives here and is handed down by binding.
    @State private var pendingBranchVerb: PendingBranchVerb?
    // Rebase onto another branch: set from the toolbar's branch submenus, confirmed by `RebaseOntoDialog`.
    @State private var pendingRebase: PendingRebase?
    @State private var showWorkspaceSearch = false
    @State private var isPaletteOpen = false
    @State private var pendingConfirmation: PendingToolbarConfirmation?
    // The action row (inside a `safeAreaInset`) can't host its confirmations either.
    @State private var showDiscardAllConfirm = false
    // Which repo's "Delete Untracked Files…" sheet is up (the action row or ⌘K).
    @State private var pendingCleanPreviewRepo: RepositoryStore?
    @State private var pendingUndo: PendingUndo?
    // Shared by `DiffView`'s Edit/Done toggle and `EditFileView`, so navigation away from an
    // unsaved edit can be guarded from up here (see `EditSession`).
    @State private var editSession = EditSession()
    // Set right before this view programmatically reverts `workspace.selectedRepoID` after a
    // guarded repo switch, so the resulting `onChange` (below) doesn't re-enter the guard.
    @State private var suppressRepoGuard = false
    // A local `.keyDown` monitor, not only the menu's `.keyboardShortcut("k")`: AppKit offers a
    // command-key event to the focused responder chain (a focused NSTextView gets first refusal)
    // before the main menu, while a local monitor runs ahead of that walk. ⌘K toggles, so pressing
    // it again closes the palette like Escape.
    @State private var cmdKMonitor: Any?
    /// The window this ContentView lives in, so the ⌘K monitor only reacts to keystrokes in it —
    /// local monitors are app-wide, and without this a second Gitunia window or the Settings
    /// window would toggle this window's palette.
    @State private var hostWindow = HostWindowBox()
    @State private var recovery = RecoveryCoordinator()

    // Recovery (reflog / reset / detached HEAD) wraps the whole body — also the environment
    // entry the toolbar and History read it from. Separate from `mainBody` for the type checker.
    var body: some View {
        mainBody.modifier(RecoveryDialogs(recovery: recovery, hostsReflog: true))
    }

    private var mainBody: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace, openWorkspace: openWorkspace, openRecent: openRecent)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                // An unreadable `workspace.json` resets every preference, including Local AI only —
                // say so once instead of letting it pass silently.
                .task(id: workspace.configLoadWarning) {
                    guard let warning = workspace.configLoadWarning else { return }
                    toasts.post(.error("Workspace", detail: warning))
                    workspace.dismissConfigLoadWarning()
                }
                .task(id: workspace.saveError) {
                    guard let error = workspace.saveError else { return }
                    toasts.post(.error("Couldn't save workspace", detail: error))
                }
                // Shared by every window: the first one to see it posts and clears it, so several
                // open windows produce one toast, not one each.
                .task(id: workspace.app.persistError) {
                    guard let error = workspace.app.persistError else { return }
                    workspace.app.dismissPersistError()
                    toasts.post(.error("Couldn't save Gitunia's settings", detail: error))
                }
        } content: {
            Group {
                if let repo = workspace.selectedRepository {
                    Group {
                        switch contentMode {
                        case .changes:
                            ChangesView(workspace: workspace, repo: repo, selectedChange: guardedSelectedChange, onRequestFileHistory: requestFileHistory)
                        case .history:
                            HistoryView(
                                repo: repo, selection: $selectedCommit, focusFilterRequested: $focusHistoryFilter,
                                fileHistoryPath: $fileHistoryPath, fileHistorySelectedPath: $fileHistorySelectedPath
                            )
                        case .compare:
                            CompareView(
                                repo: repo, workspace: workspace, base: $compareBase, head: $compareHead,
                                onOpenCommitInHistory: { navigate(toCommit: $0.hash, fallback: $0) }
                            )
                        }
                    }
                    // Fill the column from the top. A tab whose content is shorter than the column (e.g.
                    // Compare's "Nothing to compare" state) otherwise got centred vertically, dragging
                    // the Changes | History | Compare row down with it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340)
                    .safeAreaInset(edge: .top) { actionRow(for: repo) }
                } else {
                    EmptyWorkspaceView(workspace: workspace)
                }
            }
            // Hosted outside the `if let repo` branch, so it survives `selectedRepoID` matching none.
            .background(paletteTargetsHost)
        } detail: {
            if let repo = workspace.selectedRepository {
                switch contentMode {
                case .changes:
                    if let change = selectedChange {
                        DiffView(
                            repo: repo, change: change, editSession: editSession, onRequestFileHistory: requestFileHistory,
                            onNavigateToBlameCommit: { hash in navigateToBlameCommit(hash, path: change.path) },
                            activateBlameRequested: $activateBlameRequested
                        )
                    } else {
                        ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                    }
                case .history:
                    if let commit = selectedCommit {
                        CommitDiffView(
                            workspace: workspace, repo: repo, commit: commit, selectedPath: $selectedHistoryFilePath, selection: $selectedCommit,
                            preselectPath: fileHistoryPath != nil ? fileHistorySelectedPath : nil,
                            onRequestFileHistory: requestFileHistory
                        )
                    } else {
                        ContentUnavailableView("Select a commit", systemImage: "clock")
                    }
                case .compare:
                    CompareDiffView(
                        workspace: workspace, repo: repo, base: compareBase, head: compareHead,
                        selectedPath: $compareSelectedPath, onRequestFileHistory: requestFileHistory
                    )
                }
            } else {
                ContentUnavailableView("Select a repository", systemImage: "arrow.triangle.branch")
            }
        }
        // One place sets the window's title for every mode (`DiffView`/`CommitDiffView` show their
        // own identity inside their content instead): the title names the workspace — what tells
        // two windows apart — and the subtitle the selected repository and its branch.
        .navigationTitle(workspace.displayName)
        .navigationSubtitle(workspace.selectedRepository.map { Self.windowSubtitle($0.repo) } ?? "")
        .onChange(of: workspace.selectedRepoID) { oldValue, newValue in
            // Sidebar selection is a plain `List(selection: $workspace.selectedRepoID)` binding
            // (`SidebarView`) — by the time this fires, the switch has already happened, so an
            // unsaved edit is guarded by reverting it here and re-applying it from
            // `EditSession.guardNavigation`'s callback once the user says it's OK, rather than by
            // intercepting the change beforehand the way `guardedSelectedChange` below does.
            if suppressRepoGuard { suppressRepoGuard = false; return }
            guard editSession.isDirty else { restoreSelection(); return }
            suppressRepoGuard = true
            workspace.selectedRepoID = oldValue
            editSession.guardNavigation {
                suppressRepoGuard = true
                workspace.selectedRepoID = newValue
                restoreSelection()
            }
        }
        .onAppear {
            restoreSelection()
            installCmdKMonitorIfNeeded()
            // Lets a rejected-push toast's "Force push…" check its repository is still open.
            remoteOps.workspace = workspace
        }
        .background(HostWindowReader(box: hostWindow))
        .onDisappear {
            if let monitor = cmdKMonitor {
                NSEvent.removeMonitor(monitor)
                cmdKMonitor = nil
            }
        }
        .environment(\.isPaletteOpen, isPaletteOpen)
        .onChange(of: selectedChange) { _, newValue in
            guard let repo = workspace.selectedRepository else { return }
            workspace.setSelectedPath(newValue?.path, for: repo)
        }
        .onChange(of: workspace.selectedRepository?.lastError?.stderr) { _, _ in handleLastError() }
        .focusedValue(\.paletteOpen, $isPaletteOpen)
        .focusedValue(\.editorTarget, editorTarget)
        .overlay { paletteOverlay }
        .sheet(item: pendingEditorRequest) { request in
            EditorChooserSheet(request: request, workspace: workspace, coordinator: editorRequests)
        }
        .modifier(CleanPreviewSheetPresenter(pendingRepo: $pendingCleanPreviewRepo))
        .toolbar {
            if let repo = workspace.selectedRepository {
                RepoToolbarContent(
                    repo: repo,
                    showNewBranch: $showNewBranch,
                    pendingConfirmation: $pendingConfirmation,
                    pendingBranchVerb: $pendingBranchVerb,
                    pendingRebase: $pendingRebase
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await workspace.refreshAll() }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .confirmationDialog(
            "Proceed anyway?",
            isPresented: Binding(get: { pendingConfirmation != nil && !autoStashes(pendingConfirmation) },
                                 set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Do it anyway", role: .destructive) {
                if let action = pendingConfirmation?.action { Task { await action() } }
                pendingConfirmation = nil
            }
            if let target = pendingConfirmation?.stashAndSwitchTarget {
                Button("Stash and switch") { stashAndSwitch(to: target) }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text((pendingConfirmation?.issues.map(\.message) ?? []).joined(separator: "\n"))
        }
        .onChange(of: pendingConfirmation?.id) {
            if autoStashes(pendingConfirmation), let target = pendingConfirmation?.stashAndSwitchTarget {
                stashAndSwitch(to: target)
            }
        }
        .alert("New branch", isPresented: $showNewBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Create") {
                let name = newBranchName.trimmingCharacters(in: .whitespaces)
                newBranchName = ""
                guard let repo = workspace.selectedRepository, !repo.isBusy, !name.isEmpty else { return }
                Task { await repo.createBranch(name) }
            }
            Button("Cancel", role: .cancel) { newBranchName = "" }
        } message: {
            Text("Creates the branch from the current HEAD and checks it out.")
        }
        .modifier(BranchVerbDialogs(pending: $pendingBranchVerb, repo: workspace.selectedRepository))
        .modifier(UnsavedEditsDialog(editSession: editSession))
        // The window's native "edited" flag: puts the dot in the close button, and is what
        // `CloseDelegateProxy.windowShouldClose` / `AppDelegate` check before closing or quitting
        // would throw away an unsaved in-place edit (the session itself is private to this view).
        .onChange(of: editSession.isDirty, initial: true) { _, dirty in hostWindow.window?.isDocumentEdited = dirty }
        .modifier(RemoteOpsDialogs(remoteOps: remoteOps, toasts: toasts))
        .modifier(ActionRowDialogs(
            showDiscardAllConfirm: $showDiscardAllConfirm,
            pendingUndo: $pendingUndo,
            discardAllTitle: discardAllTitle,
            onDiscardAll: {
                guard let repo = workspace.selectedRepository else { return }
                Task { await repo.discardAllTracked() }
            }
        ))
    }

    /// ⌘K's "Search History…" action: switches to History mode (through the same edit-session
    /// guard as the toolbar's Changes/History switch) and asks `HistoryView`'s filter field to
    /// take focus.
    private func requestHistorySearch() {
        guardedContentMode.wrappedValue = .history
        focusHistoryFilter = true
    }

    /// Every file-history entry point (Changes' context menu, the commit diff's file list, the
    /// diff toolbar, ⌘K) funnels through here: switches to History (through the same edit-session
    /// guard as the toolbar's Changes/History switch) and puts `HistoryView` into file-history mode
    /// for `path`.
    private func requestFileHistory(_ path: String) {
        editSession.guardNavigation {
            contentMode = .history
            fileHistoryPath = path
            fileHistorySelectedPath = nil
        }
    }

    /// A Blame gutter click in `DiffView`: switches to History in file-history mode for this file,
    /// then selects the clicked commit fetched by hash (works even when it isn't in a loaded page).
    /// File history's own auto-select may race this, but both converge: the clicked commit touched
    /// this file, so it's in the follow-log.
    private func navigateToBlameCommit(_ hash: String, path: String) {
        editSession.guardNavigation {
            contentMode = .history
            fileHistoryPath = path
            fileHistorySelectedPath = nil
            guard let repo = workspace.selectedRepository else { return }
            Task {
                if let info = await repo.commitInfo(hash) {
                    selectedCommit = info
                }
            }
        }
    }

    /// Switches to History and selects `hash` in the selected repo, fetched fresh so it works even
    /// when the commit isn't in a loaded history page. Shared by Compare and `HistoryNavigator`.
    private func navigate(toCommit hash: String, fallback: CommitInfo? = nil) {
        editSession.guardNavigation {
            contentMode = .history
            guard let repo = workspace.selectedRepository else { return }
            Task {
                if let info = await repo.commitInfo(hash) ?? fallback { selectedCommit = info }
            }
        }
    }

    /// Runs `navigator.pending` once it targets this window and `restoreSelection` has already run
    /// for its repo (so the repo switch's `selectedCommit = nil` can't land after the jump).
    private func consumePendingNavigation() {
        guard let navigator, let pending = navigator.pending, navigator.targets(workspace),
              workspace.selectedRepoID == pending.repoID, restoredRepoID == pending.repoID else { return }
        navigator.pending = nil
        navigate(toCommit: pending.hash)
    }

    /// ⌘K "Go to Commit…" submit: resolve the typed ref, then jump through the navigator.
    private func goToCommit() {
        let ref = goToCommitRef
        goToCommitRef = ""
        guard let repo = goToCommitRepo else { return }
        Task {
            guard let hash = await repo.resolveCommit(ref) else {
                toasts.post(.error("No commit “\(ref)”", detail: repo.repo.name))
                return
            }
            navigator?.show(commit: hash, in: repo, preferWindow: navigator?.windowID(of: workspace))
        }
    }

    /// ⌘K's "Compare with master…" action: selects the repository (mirrors the plain repository-row
    /// behavior with no action pending) and switches to Compare for it.
    private func requestCompare(_ repo: RepositoryStore) {
        workspace.selectedRepoID = repo.id
        editSession.guardNavigation {
            contentMode = .compare
        }
    }

    /// ⌘K's "Blame": Blame only exists in `DiffView` (Changes mode), so with a file already
    /// selected this switches back to Changes first; only truly nothing to blame gets the toast.
    private func requestBlame() {
        guard selectedChange != nil else {
            toasts.post(.info("No file open", detail: "Select a file in Changes to see its blame"))
            return
        }
        editSession.guardNavigation {
            contentMode = .changes
            activateBlameRequested = true
        }
    }

    /// Split out of `body` for the type checker's time budget.
    @ViewBuilder
    private var paletteOverlay: some View {
        if isPaletteOpen {
            CommandPalette(
                workspace: workspace,
                selectedCommit: contentMode == .history ? selectedCommit : nil,
                isPresented: $isPaletteOpen,
                openWorkspace: openWorkspace,
                newWindow: newWindow,
                onRequestCleanPreview: { pendingCleanPreviewRepo = $0 },
                onRequestSearchHistory: requestHistorySearch,
                currentFilePath: editorTarget?.path,
                onRequestFileHistory: requestFileHistory,
                onRequestBlame: requestBlame,
                onRequestCompare: requestCompare,
                onRequestRebase: { branch, repo in
                    RebaseOntoRunner.request(onto: branch, on: repo, toasts: toasts, pending: $pendingRebase)
                },
                onRequestWorkspaceSearch: { showWorkspaceSearch = true },
                onRequestGoToCommit: { goToCommitRepo = $0 }
            )
        }
    }

    /// Hosts ⌘K's workspace search and Go to Commit, which can target any repository — present
    /// whenever the workspace has one, even when `refreshAll` leaves `selectedRepoID` matching none.
    @ViewBuilder
    private var paletteTargetsHost: some View {
        if !workspace.repositories.isEmpty {
            Color.clear
                .sheet(isPresented: $showWorkspaceSearch) {
                    WorkspaceSearchSheet(workspace: workspace, onOpenFile: openSearchHit, onOpenCommit: openSearchCommit)
                }
                .onChange(of: navigator?.pending) { consumePendingNavigation() }
                .alert("Go to Commit", isPresented: Binding(get: { goToCommitRepo != nil }, set: { if !$0 { goToCommitRepo = nil } })) {
                    TextField("Hash, branch or tag", text: $goToCommitRef)
                    Button("Go", action: goToCommit)
                    Button("Cancel", role: .cancel) { goToCommitRef = "" }
                } message: {
                    Text("Shows the commit in \(goToCommitRepo?.repo.name ?? "the repository")'s History.")
                }
        }
    }

    /// A workspace-search grep hit: a changed file opens in Changes (via `restoredSelectedPath`,
    /// which `restoreSelection` reads when the repo switch lands); anything else goes to the editor.
    private func openSearchHit(_ repo: RepositoryStore, path: String) {
        guard let change = Self.change(at: path, in: repo) else {
            workspace.selectedRepoID = repo.id
            editorRequests.open(repo.url.appendingPathComponent(path), configuredBundleID: workspace.config.settings.editorBundleID)
            return
        }
        workspace.setSelectedPath(path, for: repo)
        if workspace.selectedRepoID == repo.id { selectedChange = change } else { workspace.selectedRepoID = repo.id }
        guardedContentMode.wrappedValue = .changes
    }

    /// A workspace-search commit hit: `HistoryNavigator` selects the repo here and jumps once the
    /// switch has settled (see its sequencing note).
    private func openSearchCommit(_ repo: RepositoryStore, commit: CommitInfo) {
        navigator?.show(commit: commit.hash, in: repo, preferWindow: navigator?.windowID(of: workspace))
    }

    @ViewBuilder
    private func actionRow(for repo: RepositoryStore) -> some View {
        ContentActionRow(
            repo: repo,
            contentMode: guardedContentMode,
            onDiscardAllRequested: { showDiscardAllConfirm = true },
            onUndoRequested: {
                guard let repo = workspace.selectedRepository else { return }
                pendingUndo = UndoCommitRunner.request(on: repo, toasts: toasts)
            },
            onCleanUntrackedRequested: { pendingCleanPreviewRepo = repo }
        )
        // Hosted here rather than on `body` (whose modifier chain is at the type checker's limit);
        // the row exists whenever a repo — and so the toolbar's branch menu — does.
        .modifier(RebaseOntoDialog(pending: $pendingRebase))
    }

    private var discardAllTitle: String {
        let count = workspace.selectedRepository?.unstagedChanges.count ?? 0
        return "Discard changes to \(count) file\(count == 1 ? "" : "s")?"
    }

    /// The payoff for having stash at all: takes the pending checkout confirmation's already-built
    /// deferred action (the same closure "Do it anyway" would run) and runs it after stashing
    /// instead of after an override. The closure only captures the target `BranchInfo` by value
    /// (see `RepoToolbarContent`), so stashing first doesn't invalidate anything it closed over.
    /// Stops and surfaces the error (via the existing `lastError` toast watcher) if the stash
    /// itself fails, rather than checking out on top of an unresolved failure.
    private func stashAndSwitch(to target: String) {
        let confirmation = pendingConfirmation
        pendingConfirmation = nil
        guard let confirmation, let repo = workspace.selectedRepository else { return }
        let count = repo.repo.changeCount
        let from = repo.repo.branch ?? "HEAD"
        let label = repo.stashLabel(for: from)
        let toasts = toasts
        Task {
            guard await repo.stash(message: label) else { return }
            await confirmation.action()
            toasts.post(Toast(style: .info, title: repo.repo.name,
                              detail: "Stashed \(count) file\(count == 1 ? "" : "s") as '\(StashLabel.prefix)\(repo.repo.name) @ \(from)' and switched to \(target) — Restore from Recovery or the stash menu",
                              action: ToastAction(title: "Restore") {
                Task { @MainActor in
                    // By exact label + hash (stashApply re-verifies), never "the latest stash".
                    guard let item = await repo.stashItems().first(where: { $0.entry.message == label }) else { return }
                    if case .conflicts(let n) = await repo.stashApply(item, pop: true) {
                        toasts.post(.info(repo.repo.name, detail: "Restored with \(n) conflicted file\(n == 1 ? "" : "s") — the stash was kept"))
                    }
                }
            }))
        }
    }

    /// Setting on, and the checkout is blocked only by uncommitted changes: stash and switch
    /// without asking (any other blocker still gets the dialog).
    private func autoStashes(_ confirmation: PendingToolbarConfirmation?) -> Bool {
        guard let confirmation, confirmation.stashAndSwitchTarget != nil else { return false }
        return workspace.config.settings.autoStashOnSwitch && confirmation.issues.allSatisfy { $0.id == "uncommitted" }
    }

    /// `ChangesView`'s file-list selection, routed through `EditSession` so switching files while
    /// `DiffView`'s editor has unsaved edits asks first instead of losing them. Whenever the guard
    /// defers (dialog up), the setter simply doesn't apply — `ChangesView`'s own `List(selection:)`
    /// re-reads `selectedChange` and snaps its highlight back until the dialog resolves.
    private var guardedSelectedChange: Binding<FileChange?> {
        Binding(
            get: { selectedChange },
            set: { newValue in editSession.guardNavigation { selectedChange = newValue } }
        )
    }

    /// Same guard for the Changes/History switch in `ContentActionRow` — switching to History while
    /// `DiffView`'s editor has unsaved edits would otherwise unmount it silently.
    private var guardedContentMode: Binding<ContentMode> {
        Binding(
            get: { contentMode },
            set: { newValue in editSession.guardNavigation { contentMode = newValue } }
        )
    }

    private var pendingEditorRequest: Binding<EditorOpenCoordinator.Request?> {
        Binding(
            get: { editorRequests.pending },
            set: { newValue in if newValue == nil { editorRequests.pending = nil } }
        )
    }

    /// The file ⌘⇧O acts on: the selected file of whichever mode is showing.
    private var editorTarget: EditorTarget? {
        guard let repo = workspace.selectedRepository else { return nil }
        let path = switch contentMode {
        case .changes: selectedChange?.path
        case .history: selectedHistoryFilePath
        case .compare: compareSelectedPath
        }
        return path.map { EditorTarget(repoURL: repo.url, path: $0) }
    }

    /// No area is persisted with a path, so prefer the unstaged (working-tree) entry — the common
    /// case for a file being edited — before whichever area matches.
    private static func change(at path: String, in repo: RepositoryStore) -> FileChange? {
        repo.repo.changes.first { $0.path == path && $0.area == .unstaged } ?? repo.repo.changes.first { $0.path == path }
    }

    /// Restores the selected file for the newly-selected repository: the stored path if it still
    /// matches a current change, otherwise the first changed file (spec: diff on screen without a
    /// second click), otherwise nothing when the repo is clean. Always assigns a concrete value
    /// here — never `nil` as a side effect of merely switching repos — because the `selectedChange`
    /// `onChange` above persists whatever we land on, and persisting a spurious `nil` would
    /// overwrite the very state this function is about to restore.
    private func restoreSelection() {
        restoredRepoID = workspace.selectedRepoID
        defer { consumePendingNavigation() }
        selectedCommit = nil
        fileHistoryPath = nil
        fileHistorySelectedPath = nil
        compareBase = nil
        compareHead = nil
        compareSelectedPath = nil
        guard let repo = workspace.selectedRepository else {
            selectedChange = nil
            return
        }
        // Lazy stash-count refresh: `refreshStatus()` deliberately doesn't run `git stash list`
        // for every repo on every FSEvents tick, so the toolbar's count is kept current here
        // instead, once per repo selection.
        Task { await repo.refreshStashCount() }
        Task { await repo.refreshRemotes() }
        Task { await repo.hooks() }
        Task { await repo.refreshIdentity() }
        Task { await repo.refreshPullRequest() }
        if let restoredPath = repo.restoredSelectedPath, let match = Self.change(at: restoredPath, in: repo) {
            selectedChange = match
        } else {
            selectedChange = repo.repo.changes.first
        }
    }

    /// See `cmdKMonitor`. Idempotent — `.onAppear` can fire more than once, and a second monitor
    /// would toggle the palette twice per keystroke.
    private func installCmdKMonitorIfNeeded() {
        guard cmdKMonitor == nil else { return }
        cmdKMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "k",
                  let window = hostWindow.window, event.window === window else {
                return event
            }
            isPaletteOpen.toggle()
            return nil // consumed: never let the keystroke also reach a focused text view.
        }
    }

    /// Non-remote failures (stage/commit/checkout/…) have no other surface, so they become an
    /// error toast here. Fetch/pull/push are excluded — their call sites toast their own
    /// `RemoteResult`.
    private func handleLastError() {
        guard let repo = workspace.selectedRepository, let error = repo.lastError else { return }
        let remoteSubcommands: Set<String> = ["fetch", "pull", "push"]
        if let first = error.args.first, remoteSubcommands.contains(first) { return }
        let detail = [error.errorDescription, SigningFailure.hint(stderr: error.stderr)].compactMap { $0 }.joined(separator: "\n")
        toasts.post(.error(repo.repo.name, detail: detail, stderr: error.stderr, command: error.commandLine))
        repo.lastError = nil
    }
}

struct EmptyWorkspaceView: View {
    var workspace: WorkspaceStore
    var body: some View {
        // The sidebar carries the add/open buttons; this column just points there.
        if workspace.repositories.isEmpty {
            ContentUnavailableView("Add repositories to get started", systemImage: "folder.badge.plus")
        } else {
            ContentUnavailableView("Select a repository", systemImage: "arrow.triangle.branch")
        }
    }
}

extension ContentView {
    /// "gitunia — main"; just the name until the branch is known.
    static func windowSubtitle(_ repo: Repository) -> String {
        repo.branchSubtitle.isEmpty ? repo.name : "\(repo.name) — \(repo.branchSubtitle)"
    }
}
