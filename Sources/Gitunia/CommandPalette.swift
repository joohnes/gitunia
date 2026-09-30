import SwiftUI
import GituniaCore

/// ⌘K overlay: fuzzy search over repositories and a fixed action list. Presented by `ContentView`
/// as a dimmed-scrim overlay (not a `.sheet`) so it feels instant. Rows come from `PaletteRows`;
/// running them lives in `CommandPalette+Actions.swift`.
struct CommandPalette: View {
    var workspace: WorkspaceStore
    /// The commit selected in History when that's the active mode — feeds "Revert commit" /
    /// "Cherry-pick", which are always listed but need this to act on.
    var selectedCommit: CommitInfo?
    @Environment(ToastCenter.self) var toasts
    @Environment(EditorOpenCoordinator.self) var editorRequests
    @Environment(RemoteOpsCoordinator.self) var remoteOps
    // Optional: render tests host the palette without them (same convention as `ReflogButton`).
    @Environment(RecoveryCoordinator.self) var recovery: RecoveryCoordinator?
    @Environment(RepoSheets.self) var repoSheets: RepoSheets?
    @Environment(UpdateCoordinator.self) var updates: UpdateCoordinator?
    @Environment(\.openWindow) var openWindow
    @Binding var isPresented: Bool
    var openWorkspace: () -> Void
    var newWindow: () -> Void = {}
    /// Hands the picked repository to `ContentView`, which owns the "Delete Untracked Files…" sheet.
    var onRequestCleanPreview: (RepositoryStore) -> Void = { _ in }
    var onRequestSearchHistory: () -> Void = {}
    /// The file shown in the content column (either mode) — feeds "Open in editor", "File history".
    var currentFilePath: String? = nil
    var onRequestFileHistory: (String) -> Void = { _ in }
    /// Acts on whichever file is already open in Changes mode.
    var onRequestBlame: () -> Void = {}
    /// Switches the repository to the Compare tab (against whatever base `CompareView` resolves).
    var onRequestCompare: (RepositoryStore) -> Void = { _ in }
    /// `ContentView` runs `RebaseOntoRunner.request`, so the palette and the branch menu share one dialog.
    var onRequestRebase: (String, RepositoryStore) -> Void = { _, _ in }
    var onRequestWorkspaceSearch: () -> Void = {}
    var onRequestGoToCommit: (RepositoryStore) -> Void = { _ in }

    /// `initialQuery` is a test seam for the render harness to start from a query state.
    init(
        workspace: WorkspaceStore,
        selectedCommit: CommitInfo? = nil,
        isPresented: Binding<Bool>,
        openWorkspace: @escaping () -> Void,
        newWindow: @escaping () -> Void = {},
        onRequestCleanPreview: @escaping (RepositoryStore) -> Void = { _ in },
        onRequestSearchHistory: @escaping () -> Void = {},
        currentFilePath: String? = nil,
        onRequestFileHistory: @escaping (String) -> Void = { _ in },
        onRequestBlame: @escaping () -> Void = {},
        onRequestCompare: @escaping (RepositoryStore) -> Void = { _ in },
        onRequestRebase: @escaping (String, RepositoryStore) -> Void = { _, _ in },
        onRequestWorkspaceSearch: @escaping () -> Void = {},
        onRequestGoToCommit: @escaping (RepositoryStore) -> Void = { _ in },
        initialQuery: String = ""
    ) {
        self.workspace = workspace
        self.selectedCommit = selectedCommit
        self._isPresented = isPresented
        self.openWorkspace = openWorkspace
        self.newWindow = newWindow
        self.onRequestCleanPreview = onRequestCleanPreview
        self.onRequestSearchHistory = onRequestSearchHistory
        self.currentFilePath = currentFilePath
        self.onRequestFileHistory = onRequestFileHistory
        self.onRequestBlame = onRequestBlame
        self.onRequestCompare = onRequestCompare
        self.onRequestRebase = onRequestRebase
        self.onRequestWorkspaceSearch = onRequestWorkspaceSearch
        self.onRequestGoToCommit = onRequestGoToCommit
        self._query = State(initialValue: initialQuery)
    }

    @State var query: String
    @State var highlighted = 0
    @FocusState private var searchFocused: Bool
    // An action picked at the top level, waiting for a repository; shown as a chip. The palette is
    // mounted fresh on every open, so all `@State` resets without explicit teardown.
    @State var pendingAction: PaletteRows.TopLevelAction?
    // Actions with their own confirmation keep the palette open until it's answered.
    @State var pendingUndo: PendingUndo?
    @State var pendingPushAllConfirm = false
    @State var pendingStashAllConfirm = false
    @State var pendingRevert: CommitInfo?
    @State var pendingCherryPick: CommitInfo?
    // Third step: the repository is picked, now a branch (or remote). Rename isn't offered — it
    // needs free-text entry, which lives in the toolbar's branch submenu.
    @State var pendingBranchStepRepo: RepositoryStore?
    @State var pendingDeleteBranchTarget: PaletteRows.BranchEntry?
    /// Remove from Git's third step, loaded when its repository is picked.
    @State var trackedPaths: [String] = []
    @State var stashMessageTarget: RepositoryStore?
    @State var pendingPushAllTags: PendingPushAllTags?
    @State var pendingUpdateSubmodules: RepositoryStore?
    @State var pullRequestTarget: RepositoryStore?

    /// Arrow keys re-run `body` on every press; re-ranking thousands of branches each time made a
    /// held arrow key stutter, so the branch step is rebuilt only when its inputs change. A
    /// reference box so `body` can refresh it without a state write. The top level (actions and
    /// repositories, a few hundred rows at most) is cheap enough to rebuild every pass.
    final class BranchStepMemo {
        struct Key: Equatable {
            let query: String
            let action: PaletteRows.TopLevelAction
            let repo: ObjectIdentifier
            // Unchanged arrays share storage, which `==` checks first — O(1) on a highlight change.
            let branches: [BranchInfo]
            let remotes: [String]
            let paths: [String]
        }
        var key: Key?
        var value: (rows: [PaletteRows.Row], hidden: Int) = ([], 0)
    }
    @State private var branchStepMemo = BranchStepMemo()

    struct PendingPushAllTags {
        let store: RepositoryStore
        let tags: [GitTag]
        let remote: String?
    }

    var body: some View {
        // Built once per body pass; the key handlers below capture this same list.
        let (rows, hiddenCount) = currentRows
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let pendingAction {
                        // Branch step: name the repository picked in the previous step too.
                        let chip = pendingBranchStepRepo.map { "\(pendingAction.chipLabel) › \($0.repo.name)" } ?? pendingAction.chipLabel
                        Text(chip)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.brand.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.brand)
                            .fixedSize()
                            .accessibilityLabel("\(chip), pick \(pendingBranchStepRepo == nil ? "a repository" : (pendingAction.picksRemote ? "a remote" : pendingAction.picksPath ? "a file or folder" : "a branch"))")
                    }
                    TextField(
                        pendingAction == nil ? "Search repositories or run a command…" : (pendingBranchStepRepo == nil ? "Search repositories…" : (pendingAction?.picksRemote == true ? "Search remotes…" : pendingAction?.picksPath == true ? "Search tracked files and folders…" : "Search branches…")),
                        text: $query
                    )
                    .textFieldStyle(.plain)
                    .font(.title3)
                }
                .padding(14)
                .focused($searchFocused)
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.return) { runHighlighted(in: rows); return .handled }
                .onKeyPress(.escape) { isPresented = false; return .handled }
                .onKeyPress(.delete) {
                    guard query.isEmpty else { return .ignored }
                    if pendingBranchStepRepo != nil {
                        pendingBranchStepRepo = nil
                        return .handled
                    }
                    guard pendingAction != nil else { return .ignored }
                    pendingAction = nil
                    return .handled
                }

                Divider()

                if rows.isEmpty {
                    Text("No matches").foregroundStyle(.secondary).padding()
                } else {
                    // Plain `VStack`, not `LazyVStack`: a few dozen rows at most, and `LazyVStack`
                    // here laid out only its first row and never updated it as `query` changed
                    // (reproduced in CommandPaletteRenderTests). One identity per row: `row.id`.
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    rowView(row, isHighlighted: index == highlighted)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            highlighted = index
                                            run(row)
                                        }
                                }
                                // Outside `rows`, so highlight and Return never land on it.
                                if hiddenCount > 0 {
                                    Text("\(hiddenCount) more — keep typing to narrow")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 18).padding(.vertical, 7)
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: highlighted) { _, newValue in
                            guard rows.indices.contains(newValue) else { return }
                            proxy.scrollTo(rows[newValue].id, anchor: .center)
                        }
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator)
            }
            .frame(width: 480)
            .shadow(radius: 24)
            .onChange(of: query) { _, _ in highlighted = 0 }
            .onChange(of: pendingAction) { _, _ in highlighted = 0 }
            .onChange(of: pendingBranchStepRepo?.id) { _, _ in highlighted = 0 }
        }
        // Setting focus directly in `.onAppear` loses the race with the field's `NSView` being
        // attached on first mount; one runloop turn later is reliable.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .modifier(UndoCommitDialogs(pending: $pendingUndo, onConfirm: { isPresented = false }))
        .confirmationDialog(
            pushAllConfirmTitle,
            isPresented: $pendingPushAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Push All") { confirmPushAll() }
            Button("Cancel", role: .cancel) { pendingPushAllConfirm = false }
        } message: {
            Text(pushAllConfirmDetail)
        }
        .confirmationDialog(
            "Stash \(stashAllCandidates.count) repositor\(stashAllCandidates.count == 1 ? "y" : "ies")?",
            isPresented: $pendingStashAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Stash All") { confirmStashAll() }
            Button("Cancel", role: .cancel) { pendingStashAllConfirm = false }
        } message: {
            Text("Uncommitted changes (including untracked files) are stashed in: \(stashAllCandidates.map(\.repo.name).sorted().joined(separator: ", ")). Repositories mid-rebase/merge are skipped.")
        }
        .modifier(CommitPickDialogs(pendingRevert: $pendingRevert, pendingCherryPick: $pendingCherryPick,
                                    repo: workspace.selectedRepository, onConfirm: { isPresented = false }))
        .confirmationDialog(
            BranchVerbDialogs.deleteTitle(branch: pendingDeleteBranchTarget?.name ?? "", force: false),
            isPresented: Binding(get: { pendingDeleteBranchTarget != nil }, set: { if !$0 { pendingDeleteBranchTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: confirmDeleteBranch)
            Button("Cancel", role: .cancel) { pendingDeleteBranchTarget = nil }
        } message: {
            Text(BranchVerbDialogs.deleteMessage)
        }
        .modifier(StashMessagePrompt(target: $stashMessageTarget, onFinish: { isPresented = false }))
        .modifier(PullRequestSheet(target: $pullRequestTarget, onFinish: { isPresented = false }))
        .confirmationDialog(
            pendingPushAllTags.map { TagsSheet.pushAllTitle(count: $0.tags.count, remote: $0.remote) } ?? "Push all tags?",
            isPresented: Binding(get: { pendingPushAllTags != nil }, set: { if !$0 { pendingPushAllTags = nil } }),
            titleVisibility: .visible
        ) {
            Button("Push All Tags", action: confirmPushAllTags)
            Button("Cancel", role: .cancel) { pendingPushAllTags = nil }
        } message: {
            Text(pendingPushAllTags.map { TagsSheet.pushAllMessage(tags: $0.tags, remote: $0.remote) } ?? "")
        }
        .confirmationDialog(
            "Update all submodules?",
            isPresented: Binding(get: { pendingUpdateSubmodules != nil }, set: { if !$0 { pendingUpdateSubmodules = nil } }),
            titleVisibility: .visible
        ) {
            Button("Update All", action: confirmUpdateSubmodules)
            Button("Cancel", role: .cancel) { pendingUpdateSubmodules = nil }
        } message: {
            Text(SubmodulesSheet.updateMessage(repoName: pendingUpdateSubmodules?.repo.name ?? ""))
        }
    }

    // MARK: - Rows

    /// Live state → plain inputs → `PaletteRows`. `hidden` counts branch-step matches past the cap.
    private var currentRows: (rows: [PaletteRows.Row], hidden: Int) {
        if let repo = pendingBranchStepRepo, let pendingAction {
            let key = BranchStepMemo.Key(query: query, action: pendingAction, repo: ObjectIdentifier(repo),
                                         branches: repo.branches, remotes: repo.remoteNames, paths: trackedPaths)
            if branchStepMemo.key == key { return branchStepMemo.value }
            let branches = repo.branches.map { PaletteRows.BranchEntry(id: $0.id, name: $0.name, isRemote: $0.isRemote, isCurrent: $0.isCurrent) }
            let value = PaletteRows.buildBranchStep(
                branches: PaletteRows.branchStepEntries(for: pendingAction, branches: branches, remotes: repo.remoteNames, paths: trackedPaths),
                query: query
            )
            branchStepMemo.key = key
            branchStepMemo.value = value
            return value
        }
        return (PaletteRows.build(
            repositories: workspace.repositories.map {
                PaletteRows.RepoEntry(id: $0.id.path, name: $0.repo.name, hasSubmodules: !$0.submodules.isEmpty)
            },
            changeFilename: changeFilename,
            pending: pendingAction,
            query: query
        ), 0)
    }

    /// Last path component only — palette rows are narrow. `currentFilePath` is the mode-aware
    /// target `ContentView.editorTarget` resolves (Changes, History or Compare).
    private var changeFilename: String {
        (currentFilePath as NSString?)?.lastPathComponent ?? ""
    }

    @ViewBuilder
    private func rowView(_ row: PaletteRows.Row, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .repository(let entry):
                Image(systemName: "folder.fill").foregroundStyle(Theme.brand)
                Text(entry.name)
                Spacer()
                Text("Repository").font(.caption).foregroundStyle(.secondary)
            case .allRepositories:
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Theme.brand)
                Text("All repositories")
                Spacer()
            case .branch(let entry) where pendingAction?.picksPath == true:
                let isFolder = entry.name.hasSuffix("/")
                Image(systemName: isFolder ? "folder" : "doc").foregroundStyle(Theme.brand)
                Text(entry.name).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(isFolder ? "Folder" : "File").font(.caption).foregroundStyle(.secondary)
            case .branch(let entry):
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.brand)
                Text(entry.name)
                Spacer()
                Text(entry.isRemote ? "Remote" : "Local").font(.caption).foregroundStyle(.secondary)
            case .action(let action):
                Image(systemName: action.spec.icon).foregroundStyle(.secondary)
                Text(action.title(changeFilename: changeFilename))
                Spacer()
                Text("Action").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(isHighlighted ? Theme.brand.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    // MARK: - Keyboard

    private func move(_ delta: Int, in rows: [PaletteRows.Row]) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), rows.count - 1)
    }

    private func runHighlighted(in rows: [PaletteRows.Row]) {
        guard rows.indices.contains(highlighted) else { return }
        run(rows[highlighted])
    }
}
