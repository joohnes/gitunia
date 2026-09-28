import SwiftUI
import GituniaCore

/// Pure selection/staging helpers, kept free of view state so they're unit-testable from
/// `GituniaTests` (see `Tests/GituniaTests/ChangeSelectionTests.swift`).
enum ChangeSelection {
    /// Which change should become the diff pane's "focused" file after `List(selection:)` commits
    /// a new `Set`. The List only ever hands us the resulting set, not which element the user just
    /// clicked, so this infers it: an element that's new since last time (a plain click replacing
    /// the selection, or cmd/shift-click extending it) wins; a pure shrink (deselecting) keeps the
    /// previous focus if it's still in the selection, otherwise falls back to any remaining member.
    /// Sorting the candidates by path makes the result deterministic when a range-select adds more
    /// than one element at once.
    static func focusedChange(old: Set<FileChange>, new: Set<FileChange>, previousFocused: FileChange?) -> FileChange? {
        if new.isEmpty { return nil }
        let added = new.subtracting(old)
        if let first = added.sorted(by: { $0.path < $1.path }).first { return first }
        if let previousFocused, new.contains(previousFocused) { return previousFocused }
        return new.sorted { $0.path < $1.path }.first
    }

    /// Reconciles a possibly-stale `FileChange` against a fresh `changes` array after a status
    /// refresh. An exact match survives; a path still in the same `area` (status changed) is
    /// followed there; only as a last resort any area for that path — a file with staged and
    /// unstaged hunks is two `FileChange`s sharing a path. `nil` when the path is gone entirely.
    static func reconcile(_ member: FileChange, changeSet: Set<FileChange>, changes: [FileChange]) -> FileChange? {
        if changeSet.contains(member) { return member }
        return changes.first { $0.path == member.path && $0.area == member.area }
            ?? changes.first { $0.path == member.path }
    }

    struct BulkTargets {
        let toStage: [FileChange]
        let toUnstage: [FileChange]
    }

    /// The mixed-selection rule: files not yet staged get staged, staged files get unstaged —
    /// each selected file moves toward the index, never away from wherever it already is. A
    /// selection split across areas simply does both, deterministically ordered by path.
    ///
    /// Conflicted files are excluded no matter how they got into `selection`: `git add` on a
    /// conflicted path marks it resolved, which is a meaningful, hard-to-undo decision the user
    /// may not intend when they meant "stage everything I've selected". Resolving a conflict is a
    /// deliberate per-file action (Use mine / Use theirs in the Conflicts section), never a side
    /// effect of a bulk `s`/`u` keypress or "Stage" on a mixed selection.
    static func bulkTargets(for selection: Set<FileChange>) -> BulkTargets {
        let sorted = selection.filter { $0.status != .conflicted }.sorted { $0.path < $1.path }
        return BulkTargets(toStage: sorted.filter { $0.area != .staged }, toUnstage: sorted.filter { $0.area == .staged })
    }
}

struct ChangesView: View {
    var workspace: WorkspaceStore
    var repo: RepositoryStore
    @Binding var selectedChange: FileChange?
    /// "Show File History" from a file's context menu — routes to `ContentView.requestFileHistory`,
    /// same "hand the target up" shape as `EditorOpenCoordinator`. Only offered for a single-file
    /// selection (`--follow` needs one path); default no-op so existing callers/tests are unaffected.
    var onRequestFileHistory: (String) -> Void = { _ in }
    @Environment(EditorOpenCoordinator.self) private var editorRequests
    @Environment(ToastCenter.self) private var toasts
    @Environment(RepoSheets.self) private var repoSheets: RepoSheets?
    // True while the ⌘K palette is up: guards the `s`/`u` handlers and returns focus to the
    // list when the palette closes.
    @Environment(\.isPaletteOpen) private var isPaletteOpen
    // Named focus for the List so closing the palette can put it back — see the `onChange` below.
    @FocusState private var listFocused: Bool
    @State private var selection: Set<FileChange> = []
    @State private var filterText = ""
    @State private var pendingDiscard: [FileChange] = []
    @State private var showAbortOperationConfirm = false
    /// Flat/tree toggle, defaulting to flat so existing users see no change on launch.
    @AppStorage("changesView.treeMode") private var treeMode = false
    /// Collapsed directory ids, keyed by `FileTreeNode.id` (stable across rebuilds, never array
    /// position). Absence means expanded. Session-only — it has to survive FSEvents rebuilds,
    /// not app launches.
    @State private var collapsedDirectories: Set<String> = []

    /// The List's own selection binding. Every user-driven selection change (click, cmd-click,
    /// shift-range, arrow keys) flows through here exactly once, so `selection` and the focused
    /// `selectedChange` are updated together from a single mutation point — there's no separate
    /// `onChange(of: selection)` racing this one. Programmatic rewrites of `selection` (status-
    /// refresh reconciliation below) go straight to the `@State` var and deliberately bypass this
    /// binding, so they never get mistaken for a user click and steal focus.
    private var listSelection: Binding<Set<FileChange>> {
        Binding(
            get: { selection },
            set: { newValue in
                selectedChange = ChangeSelection.focusedChange(old: selection, new: newValue, previousFocused: selectedChange)
                selection = newValue
            }
        )
    }

    var body: some View {
        let visible = visibleLists
        VStack(spacing: 0) {
            if let operation = repo.operation {
                OperationBanner(
                    operation: operation,
                    continueDisabled: !repo.conflictedChanges.isEmpty,
                    onContinue: { Task { _ = await repo.continueOperation() } },
                    onSkip: { Task { _ = await repo.skipOperation() } },
                    onAbort: { showAbortOperationConfirm = true }
                )
                Divider()
            }
            if !repo.repo.changes.isEmpty {
                filterField
                Divider()
            }
            List(selection: listSelection) {
                conflictsSection(visible.conflicted)
                if treeMode {
                    treeSection("Staged", visible.staged)
                    treeSection("Changes", visible.unstaged)
                    treeSection("Untracked", visible.untracked)
                } else {
                    section("Staged", visible.staged)
                    section("Changes", visible.unstaged)
                    section("Untracked", visible.untracked)
                }
            }
            // Attached to the List itself (not an ancestor) so these only fire while the List
            // holds focus. CommitBox's TextField/TextEditor and the filter field above are
            // siblings, not descendants, of the List, so onKeyPress here is outside their
            // focus/responder chain entirely — typing "s" into the commit message or the filter
            // never reaches this handler. Arrow-key selection needs no code: List(selection:)
            // already moves the selection on ↑/↓ when it has focus.
            //
            // `.focusable(!isPaletteOpen)` keeps the List from becoming first responder under the
            // palette; the `isPaletteOpen` guards stop "s"/"u" even if it somehow did.
            .focused($listFocused)
            .focusable(!isPaletteOpen)
            .onKeyPress("s") {
                guard !isPaletteOpen else { return .ignored }
                let targets = ChangeSelection.bulkTargets(for: visibleSelection).toStage
                guard !targets.isEmpty else { return .ignored }
                Task { for change in targets { await repo.stage(change) } }
                return .handled
            }
            .onKeyPress("u") {
                guard !isPaletteOpen else { return .ignored }
                let targets = ChangeSelection.bulkTargets(for: visibleSelection).toUnstage
                guard !targets.isEmpty else { return .ignored }
                Task { for change in targets { await repo.unstage(change) } }
                return .handled
            }
            // Same Quick Look toggle as Finder — the working-tree copy of whichever file is
            // focused, not the diff. `presentOrDismiss` handles the open/close toggle itself.
            .onKeyPress(" ") {
                guard !isPaletteOpen, let selectedChange else { return .ignored }
                QuickLookPanelPresenter.shared.presentOrDismiss(repo.url.appendingPathComponent(selectedChange.path))
                return .handled
            }
            .overlay {
                if repo.repo.changes.isEmpty {
                    ContentUnavailableView("Clean", systemImage: "checkmark.circle", description: Text("No changes"))
                } else if !filterText.isEmpty && visible.count == 0 {
                    ContentUnavailableView.search(text: filterText)
                }
            }
            Divider()
            CommitBox(workspace: workspace, repo: repo)
                .padding(12)
        }
        .overlay(alignment: .top) { if repo.isBusy { ProgressView().controlSize(.small).padding(6) } }
        .confirmationDialog(pendingDiscard.count == 1 ? "Discard changes to \(pendingDiscard[0].path)?" : "Discard changes to \(pendingDiscard.count) files?",
                            isPresented: Binding(get: { !pendingDiscard.isEmpty }, set: { if !$0 { pendingDiscard = [] } }),
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                let targets = pendingDiscard
                pendingDiscard = []
                Task { for change in targets { await repo.discard(change) } }
            }
        } message: {
            Text(discardMessage)
        }
        .confirmationDialog(abortOperationTitle, isPresented: $showAbortOperationConfirm, titleVisibility: .visible) {
            Button("Abort", role: .destructive) { Task { _ = await repo.abortOperation() } }
        } message: {
            Text("This stops the \(repo.operation?.label ?? "operation") and restores the branch to its state before it started. Any conflict resolution you've done so far is discarded.")
        }
        .onAppear {
            if selection.isEmpty, let selectedChange { selection = [selectedChange] }
        }
        // Per-repo view state (filter text, collapsed dirs, pending discard confirmation, and the
        // multi-selection) must not survive a repo switch — see `CommitBox`'s and `HistoryView`'s
        // matching `onChange(of: repo.id)`. `selection` is written directly (not via `listSelection`)
        // for the same reason the reconciliation below does: this is a programmatic rewrite, not a
        // user click, and must not race `onChange(of: selection)`. Seeded from `selectedChange`
        // rather than cleared to `[]` because `ContentView.restoreSelection` may leave `selectedChange`
        // equal (by value) to what it already was, in which case `onChange(of: selectedChange)` below
        // never fires to resync `selection` for us.
        .onChange(of: repo.id) {
            filterText = ""
            collapsedDirectories = []
            pendingDiscard = []
            selection = selectedChange.map { [$0] } ?? []
        }
        .onChange(of: repo.repo.changes) { _, changes in
            let changeSet = Set(changes)
            // Reconcile the whole selection the same way the single-file logic below already
            // does: a member whose exact (path, area) still exists survives untouched; a member
            // whose path moved to another area is followed; a member that's gone entirely (staged
            // and committed, discarded, …) is dropped. Written straight to the `@State` var, not
            // through `listSelection`, so this never gets read as a user click stealing focus.
            let reconciled = Set(selection.compactMap { ChangeSelection.reconcile($0, changeSet: changeSet, changes: changes) })
            if reconciled != selection { selection = reconciled }
            guard let current = selectedChange else { return }
            if changeSet.contains(current) { return }
            // Same path moved to another area (stage/unstage) → follow it; otherwise deselect.
            selectedChange = ChangeSelection.reconcile(current, changeSet: changeSet, changes: changes)
        }
        .onChange(of: selectedChange) { _, newValue in
            // Reflects an *externally*-driven focus change (ContentView's restoreSelection on
            // repo switch, or the follow/deselect above) into the multi-select set. Our own writes
            // via `listSelection` already leave `selection` containing `newValue`, so this is a
            // no-op for those — it only fires the resync when something outside this mutation path
            // moved the focus out from under the current selection.
            guard let newValue else {
                if !selection.isEmpty { selection = [] }
                return
            }
            if !selection.contains(newValue) { selection = [newValue] }
        }
        // The palette closing hands keyboard focus back to the file list, so ↑/↓ and s/u work
        // again without an extra click.
        .onChange(of: isPaletteOpen) { wasOpen, isOpen in
            if wasOpen && !isOpen { listFocused = true }
        }
    }

    private var abortOperationTitle: String {
        let branch = repo.repo.isDetached ? "your branch" : (repo.repo.branch ?? "your branch")
        return repo.operation?.stopConfirmTitle(branch: branch) ?? "Abort the operation?"
    }

    private func filtered(_ changes: [FileChange]) -> [FileChange] {
        FuzzyMatch.rank(changes, query: filterText, key: \.path)
    }

    /// The four sections after the filter, computed once per `body`.
    private struct VisibleLists {
        let conflicted, staged, unstaged, untracked: [FileChange]
        var count: Int { conflicted.count + staged.count + unstaged.count + untracked.count }
        var all: Set<FileChange> { Set(conflicted + staged + unstaged + untracked) }
    }

    private var visibleLists: VisibleLists {
        VisibleLists(conflicted: filtered(repo.conflictedChanges), staged: filtered(repo.stagedChanges),
                     unstaged: filtered(repo.unstagedChanges), untracked: filtered(repo.untrackedChanges))
    }

    /// What `s`/`u` may act on: `selection` isn't trimmed when the filter hides rows, and acting
    /// on a file the user can no longer see would be surprising.
    private var visibleSelection: Set<FileChange> { selection.intersection(visibleLists.all) }

    private var discardMessage: String {
        if pendingDiscard.count == 1 {
            return pendingDiscard[0].status == .untracked ? "The file will be deleted." : "This cannot be undone."
        }
        let untrackedCount = pendingDiscard.filter { $0.status == .untracked }.count
        if untrackedCount == 0 { return "This cannot be undone." }
        if untrackedCount == pendingDiscard.count { return "This cannot be undone. All \(untrackedCount) files are untracked and will be deleted." }
        return "This cannot be undone. \(untrackedCount) of these files are untracked and will be deleted."
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Button { filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            TreeModeToggle(treeMode: $treeMode)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder
    private func section(_ title: String, _ changes: [FileChange]) -> some View {
        if !changes.isEmpty {
            let lockfiles = changes.filter { ChangeClassification.isLockfile($0.path) }
            Section("\(title) (\(changes.count))") {
                ForEach(changes.filter { !ChangeClassification.isLockfile($0.path) }) { flatRow($0) }
                if !lockfiles.isEmpty {
                    // Collapsed by default, so the synthetic key's *presence* in
                    // `collapsedDirectories` means expanded — the inverse of a directory's.
                    let key = "\u{0}lockfiles:\(title)"
                    let expanded = collapsedDirectories.contains(key)
                    FileTreeRowView(row: FileTreeRow<FileChange>(id: key, depth: 0, kind: .directory(name: "Lockfiles (\(lockfiles.count))", path: "", isExpanded: expanded)),
                                    onToggle: toggleCollapsed) { _, _ in EmptyView() }
                    if expanded {
                        ForEach(lockfiles) { flatRow($0) }
                    }
                }
            }
        }
    }

    private func flatRow(_ change: FileChange) -> some View {
        ChangeRow(change: change, isLFS: GitAttributes.isLFSTracked(change.path, rules: repo.attributeRules))
            .tag(change)
            .contextMenu { menu(for: change) }
    }

    /// Pinned above Staged/Changes/Untracked whenever any file is conflicted, regardless of tree
    /// vs. flat mode — a conflict is urgent enough that it isn't worth doubling this into a
    /// tree-mode variant too. Rows still `.tag()` into the same `selection` so arrow-key
    /// navigation and click-to-preview work exactly like every other row; `bulkTargets` is what
    /// keeps `s`/`u` and multi-file "Stage"/"Unstage" from ever touching them (see its doc comment).
    @ViewBuilder
    private func conflictsSection(_ changes: [FileChange]) -> some View {
        if !changes.isEmpty {
            Section("Conflicts (\(changes.count))") {
                if repo.rebaseInProgress {
                    // "Ours"/"theirs" are inverted during a rebase compared to every other operation
                    // (merge, cherry-pick, revert) — verified against real git output (see
                    // RepositoryStore.useOurs's doc comment). Labelled "Keep Upstream"/"Keep My
                    // Commit" below rather than reusing "Use Mine"/"Use Theirs", which would
                    // silently mean the opposite of what they say everywhere else.
                    Text("A rebase is in progress. \"Keep Upstream\" keeps the code you're rebasing onto; \"Keep My Commit\" keeps the commit being replayed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(changes) { change in
                    ConflictRow(
                        change: change,
                        // Also with no operation: a conflicting stash apply/pop writes no operation
                        // file, and these buttons are then the only in-app way to resolve it.
                        offerResolution: true,
                        mineLabel: mineLabel,
                        theirsLabel: theirsLabel
                    ) {
                        Task { await repo.useOurs(change) }
                    } useTheirs: {
                        Task { await repo.useTheirs(change) }
                    }
                    .tag(change)
                    .contextMenu { conflictMenu(for: change) }
                }
            }
        }
    }

    /// "Keep Upstream" during a rebase (inverted meaning, see above); "Use Mine" for every other
    /// operation — merge, cherry-pick and revert all agree that "ours" is the current branch
    /// (verified against real git output for cherry-pick/revert conflicts, same as merge already was).
    private var mineLabel: String { repo.rebaseInProgress ? "Keep Upstream" : repo.operation == nil ? "Keep Current" : "Use Mine" }
    private var theirsLabel: String { repo.rebaseInProgress ? "Keep My Commit" : repo.operation == nil ? "Keep Stashed" : "Use Theirs" }

    @ViewBuilder
    private func conflictMenu(for change: FileChange) -> some View {
        Button(mineLabel, systemImage: "arrow.left.circle") { Task { await repo.useOurs(change) } }
        Button(theirsLabel, systemImage: "arrow.right.circle") { Task { await repo.useTheirs(change) } }
        Divider()
        Button("Open in Editor", systemImage: "square.and.pencil") {
            editorRequests.open(repo.url.appendingPathComponent(change.path), configuredBundleID: workspace.config.settings.editorBundleID)
        }
        Button("Reveal in Finder", systemImage: "finder") {
            NSWorkspace.shared.activateFileViewerSelecting([repo.url.appendingPathComponent(change.path)])
        }
    }

    /// Tree-mode counterpart of `section`: same outer per-area grouping and count, built from
    /// `FileTree.build`. The filter above already narrows `changes` before this runs, so a filter
    /// like "sbv" naturally yields a tree containing only the matching files and the directory
    /// rows that lead to them — nothing extra to handle here.
    @ViewBuilder
    private func treeSection(_ title: String, _ changes: [FileChange]) -> some View {
        if !changes.isEmpty {
            Section("\(title) (\(changes.count))") {
                // Salted with the section title, not `FileChange.area` — untracked files carry
                // `area == .unstaged` too, which would couple their directories' expand state.
                let tree = FileTree.build(from: changes, path: \.path, salt: title)
                ForEach(FileTree.flatten(tree, collapsed: collapsedDirectories)) { row in
                    treeRow(row)
                }
            }
        }
    }

    /// A directory row only toggles `collapsedDirectories` — it's never `.tag()`-ed, so only file
    /// rows are selectable, exactly as in flat mode. `List` sees a flat `ForEach` over
    /// pre-flattened rows (`FileTree.flatten`), so no nested `DisclosureGroup` can desynchronise
    /// row geometry on collapse.
    @ViewBuilder
    private func treeRow(_ row: FileTreeRow<FileChange>) -> some View {
        let rowView = FileTreeRowView(row: row, onToggle: toggleCollapsed) { change, _ in
            ChangeRow(change: change, showsPath: false, isLFS: GitAttributes.isLFSTracked(change.path, rules: repo.attributeRules))
        }
        switch row.kind {
        case .directory(_, let path, _):
            rowView
                .contextMenu {
                Button("Ignore This Folder", systemImage: "eye.slash") {
                    addToGitignore(GitignorePattern.folder(path), tracked: false)
                }
                Button("Remove Folder from Git…", systemImage: "minus.circle") {
                    repoSheets?.active = .removeFromGit(repo, [path + "/"])
                }
            }
        case .file(let change, _):
            rowView
                .tag(change)
                .contextMenu { menu(for: change) }
        }
    }

    private func toggleCollapsed(_ id: String) {
        if !collapsedDirectories.insert(id).inserted { collapsedDirectories.remove(id) }
    }

    /// Right-clicking a row that's part of the current multi-selection acts on the whole
    /// selection (Finder's convention); right-clicking a row outside it acts on just that row.
    @ViewBuilder
    private func menu(for change: FileChange) -> some View {
        let targets = selection.contains(change) && selection.count > 1 ? selection.sorted { $0.path < $1.path } : [change]
        let bulk = ChangeSelection.bulkTargets(for: Set(targets))
        if !bulk.toStage.isEmpty {
            Button(bulk.toStage.count == targets.count ? "Stage" : "Stage (\(bulk.toStage.count))", systemImage: "plus.circle") {
                Task { for change in bulk.toStage { await repo.stage(change) } }
            }
        }
        if !bulk.toUnstage.isEmpty {
            Button(bulk.toUnstage.count == targets.count ? "Unstage" : "Unstage (\(bulk.toUnstage.count))", systemImage: "minus.circle") {
                Task { for change in bulk.toUnstage { await repo.unstage(change) } }
            }
        }
        Divider()
        Button(targets.count == 1 ? "Discard Changes" : "Discard Changes (\(targets.count))", systemImage: "arrow.uturn.backward", role: .destructive) {
            pendingDiscard = targets
        }
        Button(targets.count == 1 ? "Stash This File" : "Stash \(targets.count) Files", systemImage: "tray.and.arrow.down") {
            Task { await StashRunner.stashSelected(targets, on: repo, toasts: toasts) }
        }
        .disabled(repo.isBusy || repo.operation != nil)
        Divider()
        Button(targets.count == 1 ? "Open in Editor" : "Open \(targets.count) in Editor", systemImage: "square.and.pencil") {
            for change in targets {
                editorRequests.open(repo.url.appendingPathComponent(change.path), configuredBundleID: workspace.config.settings.editorBundleID)
            }
        }
        Button("Reveal in Finder", systemImage: "finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map { repo.url.appendingPathComponent($0.path) })
        }
        // Single-file only — `git log --follow` only ever follows one path.
        if targets.count == 1 {
            Button("Show File History", systemImage: "clock") { onRequestFileHistory(targets[0].path) }
        }
        let tracked = targets.filter { $0.status != .untracked }.map(\.path)
        if !tracked.isEmpty {
            Button(tracked.count == 1 ? "Remove from Git…" : "Remove \(tracked.count) from Git…", systemImage: "minus.circle") {
                repoSheets?.active = .removeFromGit(repo, Array(Set(tracked)).sorted())
            }
        }
        Divider()
        ignoreMenu(for: change)
    }

    /// "Ignore" submenu: always built from the row that was right-clicked, not the
    /// bulk `targets` a multi-select menu otherwise acts on — a `.gitignore` pattern is about one
    /// file's identity, not "do this to everything I have selected".
    @ViewBuilder
    private func ignoreMenu(for change: FileChange) -> some View {
        let folder = (change.path as NSString).deletingLastPathComponent
        Menu("Ignore", systemImage: "eye.slash") {
            Button("This File") { addToGitignore(GitignorePattern.file(change.path), tracked: change.status != .untracked) }
            if !folder.isEmpty {
                Button("This Folder") { addToGitignore(GitignorePattern.folder(folder), tracked: change.status != .untracked) }
            }
            if let ext = GitignorePattern.extensionGlob(for: change.path) {
                Button("All \(ext) Files") { addToGitignore(ext, tracked: change.status != .untracked) }
            }
        }
    }

    /// `tracked` is whether the file git already tracks (so ignoring it here doesn't untrack it —
    /// `RepositoryStore.addToGitignore` only ever touches `.gitignore`, never the index). Note
    /// deliberately always shown for a tracked file regardless of whether the pattern was newly
    /// added or already present, since either way "Stop Tracking" is still the separate step the
    /// user might be looking for.
    private func addToGitignore(_ pattern: String, tracked: Bool) {
        Task {
            let added = await repo.addToGitignore(pattern)
            var detail = added ? "Added \(pattern) to .gitignore" : "\(pattern) is already in .gitignore"
            if tracked {
                detail += " — this file is already tracked, so ignoring it doesn't stop git from tracking it (that's a separate \"Stop Tracking\" step, not done here)"
            }
            toasts.post(.info(repo.repo.name, detail: detail))
        }
    }
}
