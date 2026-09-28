import SwiftUI
import GituniaCore

struct SidebarView: View {
    @Bindable var workspace: WorkspaceStore
    @Environment(ToastCenter.self) private var toasts
    @Environment(RemoteOpsCoordinator.self) private var remoteOps
    @State private var editingTagsFor: RepositoryStore?
    /// Optional so views rendered without `GituniaApp`'s environment (render tests) still work.
    @Environment(RepoSheets.self) private var repoSheets: RepoSheets?
    var openWorkspace: (() -> Void)? = nil
    var openRecent: ((URL) -> Void)? = nil
    /// ⌘ held: rows 1–9 show their ⌘n index. Internal (not private) so render tests can force it on.
    @State var showIndices = false
    @State private var flagsMonitor: Any?

    var body: some View {
        List(selection: $workspace.selectedRepoID) {
            // Inside the List, not an overlay: it then starts below the filter header and scrolls
            // when the window is short, instead of drawing over the header.
            if !workspace.isScanning, workspace.fileURL != nil, workspace.repositories.isEmpty, workspace.missingPaths.isEmpty {
                SidebarEmptyActions(workspace: workspace, repoSheets: repoSheets,
                                    openWorkspace: openWorkspace, openRecent: openRecent)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(WorkspaceStore.sidebarOrder(workspace.visibleRepositories).enumerated()), id: \.element.repo.id) { index, row in
                let store = row.repo
                RepoRow(store: store, toasts: toasts, remoteOps: remoteOps,
                        isSelected: workspace.selectedRepoID == store.id, showsActivity: workspace.sort == .recent)
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .overlay(alignment: .topTrailing) {
                        if showIndices && index < 9 {
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .offset(x: 6, y: -2) // into the row inset, clear of the push/pull buttons
                        }
                    }
                    .tag(store.id)
                    .dropDestination(for: URL.self) { urls, _ in
                        ApplyPatchSheet.handleDrop(urls, on: store, workspace: workspace, sheets: repoSheets)
                    }
                    .contextMenu {
                        Button("Edit Tags…", systemImage: "tag") {
                            editingTagsFor = store
                        }
                        Toggle("Local AI only", isOn: Binding(
                            get: { store.repo.localAIOnly },
                            set: { workspace.setLocalAIOnly($0, for: store) }
                        ))
                        .help("Only a local model generates commit messages for this repository; cloud AI providers are never used.")
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.url])
                        }
                        Button("Remove from Workspace", systemImage: "minus.circle") {
                            WorkspaceActions.remove(store, from: workspace, toasts: toasts)
                        }
                        Button("Remotes…", systemImage: "network") { repoSheets?.active = .remotes(store) }
                        Button("Worktrees…", systemImage: "arrow.triangle.branch") { repoSheets?.active = .worktrees(store) }
                        if !store.submodules.isEmpty {
                            Button("Submodules…", systemImage: "shippingbox") { repoSheets?.active = .submodules(store) }
                        }
                        Divider()
                        Button("Fetch") { Task { await remoteOps.requestFetch(on: store, toasts: toasts) } }
                            .disabled(store.isBusy)
                        Button("Pull") { Task { await remoteOps.requestPull(on: store, toasts: toasts) } }
                            .disabled(store.isBusy || !store.hasUpstream || store.repo.behind == 0)
                        Button("Push") { Task { await remoteOps.requestPush(on: store, toasts: toasts) } }
                            .disabled(store.isBusy || (store.hasUpstream && store.repo.ahead == 0))
                        Divider()
                        Button("Force Push…", systemImage: "exclamationmark.triangle") {
                            remoteOps.requestForcePush(on: store, toasts: toasts)
                        }
                        .disabled(store.isBusy || !store.hasUpstream)
                    }
            }
            ForEach(workspace.missingPaths, id: \.self) { path in
                MissingRepoRow(path: path)
                    .contextMenu {
                        Button("Remove from Workspace", systemImage: "minus.circle") { workspace.removeMissing(path) }
                        Button("Reveal Parent in Finder") {
                            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                            NSWorkspace.shared.activateFileViewerSelecting([parent])
                        }
                    }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    TextField("Filter repositories", text: $workspace.searchQuery)
                        .textFieldStyle(.plain)
                    if !workspace.searchQuery.isEmpty {
                        Button {
                            workspace.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Menu {
                        ForEach(RepoSort.allCases, id: \.self) { option in
                            Button {
                                workspace.sort = option
                            } label: {
                                if workspace.sort == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sort repositories")
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)

                ScopeChipsRow(chips: workspace.scopeChips, scope: $workspace.scope)
                    .padding(.horizontal, 10)

                if let bulk = workspace.bulk {
                    BulkProgressRow(bulk: bulk)
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.vertical, 6)
            .background(.bar)
            .animation(.default, value: workspace.bulk)
        }
        .navigationTitle(workspace.displayName)
        .overlay {
            if workspace.isScanning { ProgressView("Scanning…") }
        }
        .sheet(item: $editingTagsFor) { store in
            TagEditorSheet(store: store, workspace: workspace)
        }
        .onAppear {
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                showIndices = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            showIndices = false
        }
    }
}

/// A single repo whose folder is gone (moved, deleted, or on an unmounted disk). Kept visible
/// rather than dropped so the user decides — it may come back when the disk does.
private struct MissingRepoRow: View {
    let path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
            Text("Missing").font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .opacity(0.6)
        .help(path)
    }
}

/// Horizontally scrolling scope chips — `All 13`, `Changed 4`, then one per tag. Exactly one is
/// active at a time, tinted with `Theme.brand`; the rest are neutral capsules.
private struct ScopeChipsRow: View {
    let chips: [ScopeChip]
    @Binding var scope: RepoScope

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    ScopeChipButton(chip: chip, isActive: chip.scope == scope) {
                        scope = chip.scope
                    }
                }
            }
        }
    }
}

private struct ScopeChipButton: View {
    let chip: ScopeChip
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(chip.label)
                Text("\(chip.count)")
                    .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
            }
            .font(.caption.weight(isActive ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isActive ? Theme.brand : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct BulkProgressRow: View {
    let bulk: BulkOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(bulk.kind.rawValue.capitalized)ing… \(bulk.completed)/\(bulk.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(bulk.completed), total: Double(max(bulk.total, 1)))
                .progressViewStyle(.linear)
        }
    }
}

struct RepoRow: View {
    let store: RepositoryStore
    let toasts: ToastCenter
    let remoteOps: RemoteOpsCoordinator
    var isSelected = false
    /// "Recent activity" sort: the caption gets the relative time the sort is keyed on.
    var showsActivity = false
    @State private var isHovering = false
    /// Which of this row's remote buttons currently has an `await` in flight. `store.isBusy` covers
    /// *any* operation on the repo (including ones started elsewhere), so it can't tell us which
    /// button to spin — this is what makes that distinction.
    @State private var runningAction: RemoteKind?

    private var repo: Repository { store.repo }

    /// "Rebase in progress", "Merge in progress — 2 conflicted files", or just "1 conflicted file".
    private var attentionHelp: String {
        let n = store.conflictedChanges.count
        let conflicts = n == 0 ? nil : "\(n) conflicted file\(n == 1 ? "" : "s")"
        guard let op = store.operation else { return conflicts ?? "" }
        let head = "\(op.label.prefix(1).uppercased())\(op.label.dropFirst()) in progress"
        return conflicts.map { "\(head) — \($0)" } ?? head
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: !repo.isAvailable ? "folder.badge.questionmark" : store.worktreeParent != nil ? "arrow.triangle.branch" : "folder.fill")
                .foregroundStyle(repo.hasChanges ? Theme.brand : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(repo.name).fontWeight(repo.hasChanges ? .semibold : .regular)
                    // Mail-style unread dot: changed since the user last had this repo selected.
                    if store.hasUnseenChanges && !isSelected {
                        Circle().fill(Theme.brand).frame(width: 6, height: 6).help("New since you last viewed it")
                    }
                }
                HStack(spacing: 6) {
                    if showsActivity, let activity = store.lastActivity {
                        TimelineView(.everyMinute) { context in
                            Text(RelativeDate.string(for: activity, relativeTo: context.date))
                        }
                        .help(RelativeDate.absolute(activity))
                    }
                    if repo.branch != nil {
                        Label(repo.branchLabel, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                    }
                    if repo.ahead > 0 { Text("↑\(repo.ahead)") }
                    if repo.behind > 0 { Text("↓\(repo.behind)") }
                    // How far the current branch has drifted from the Compare base — only shown when it's actually a different branch (see
                    // `RepositoryStore.refreshBaseAheadCountIfNeeded`).
                    if let baseAhead = store.baseAheadCount, baseAhead > 0, let base = store.baseAheadBranch {
                        Text("↑\(baseAhead) vs \(base)").foregroundStyle(Theme.brand)
                    }
                    if store.needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.status(.modified)).help(attentionHelp)
                    }
                    if store.hasOutdatedSubmodules { Image(systemName: "shippingbox").foregroundStyle(Theme.brand).help("Submodules not at their recorded commits") }
                    if store.fetchCadence == .intensive {
                        Image(systemName: "bolt.fill").foregroundStyle(Theme.brand).help("Auto-fetch: intensive")
                    } else if store.fetchCadence == .paused {
                        Image(systemName: "pause.circle").help("Auto-fetch: paused")
                    }
                    ForEach(repo.tags.sorted(), id: \.self) { Text($0).padding(.horizontal, 4).background(Color.secondary.opacity(0.15), in: Capsule()) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if repo.hasChanges {
                Text("\(repo.changeCount)")
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.brand.opacity(0.2), in: Capsule())
            }
            hoverActions
        }
        // Fixed height so the bigger 26pt buttons never make a row taller than its neighbours,
        // whether or not the buttons happen to be visible right now.
        .frame(minHeight: 34)
        .opacity(repo.isAvailable ? 1 : 0.5)
        .help([store.worktreeParent.map { "Worktree of \($0.lastPathComponent) (\($0.path))" },
               repo.lastCommitAuthor.flatMap { store.agentProfile.matches(author: $0, email: repo.lastCommitEmail ?? "") ? "Last commit by agent" : nil }]
            .compactMap { $0 }.joined(separator: "\n"))
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 4) {
            RemoteActionButton(
                systemImage: "arrow.down.circle",
                count: repo.behind,
                isRunning: runningAction == .pull,
                // Something to pull is worth showing quietly all the time, not just on hover —
                // that's the whole point of making these easier to click.
                alwaysVisible: repo.behind > 0,
                rowIsHovering: isHovering,
                isDisabled: store.isBusy || !store.hasUpstream || repo.behind == 0,
                help: "Pull"
            ) {
                Task { await runRemote(.pull) }
            }

            RemoteActionButton(
                systemImage: "arrow.up.circle",
                count: repo.ahead,
                isRunning: runningAction == .push,
                alwaysVisible: repo.ahead > 0,
                rowIsHovering: isHovering,
                isDisabled: store.isBusy || (store.hasUpstream && repo.ahead == 0),
                help: "Push"
            ) {
                Task { await runRemote(.push) }
            }
        }
    }

    private func runRemote(_ kind: RemoteKind) async {
        runningAction = kind
        defer { runningAction = nil }
        switch kind {
        case .pull: await remoteOps.requestPull(on: store, toasts: toasts)
        case .push: await remoteOps.requestPush(on: store, toasts: toasts)
        case .fetch: await remoteOps.requestFetch(on: store, toasts: toasts)
        case .stash: break // bulk-only kind, never a row button
        }
    }
}

/// One pull/push glyph button with a comfortably clickable ~26pt square hit area, a hover
/// highlight, and a spinner swapped in while its own action is running.
private struct RemoteActionButton: View {
    let systemImage: String
    let count: Int
    let isRunning: Bool
    let alwaysVisible: Bool
    let rowIsHovering: Bool
    let isDisabled: Bool
    let help: String
    let action: () -> Void

    @State private var isHoveringButton = false

    private var isVisible: Bool { alwaysVisible || rowIsHovering || isRunning }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: systemImage)
                            .font(.system(size: 15))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 9).monospacedDigit())
                        }
                    }
                }
            }
            .frame(width: 26, height: 26)
            .background(isHoveringButton ? Color.secondary.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        // Keep full color while running so a disabled style doesn't make the spinner look broken.
        .opacity(isVisible ? (isDisabled && !isRunning ? 0.5 : 1) : 0)
        .allowsHitTesting(isVisible && !isDisabled)
        .onHover { isHoveringButton = $0 }
        .help(help)
    }
}

/// The sidebar's empty state once a workspace is open but holds no repositories.
struct SidebarEmptyActions: View {
    var workspace: WorkspaceStore
    var repoSheets: RepoSheets?
    @Environment(ToastCenter.self) private var toasts
    /// Set by the app; nil in render tests. Opens a workspace file (File ▸ Open Workspace…).
    var openWorkspace: (() -> Void)? = nil
    var openRecent: ((URL) -> Void)? = nil

    /// Compact and left-aligned, not a `ContentUnavailableView`: this lives in the sidebar, which
    /// can be ~200 pt wide, where a centred large-title placeholder wrapped word by word.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.file.isEmpty ? "Empty workspace" : "No repositories").font(.headline)
                Text(workspace.file.isEmpty
                     ? "Add a repository, or a folder whose repositories should all join — including new ones later."
                     : "Nothing with a .git up to 3 levels deep in the linked folders yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                action("Add Repos in Folder…", "folder.badge.plus") { WorkspaceActions.addReposInFolder(to: workspace, toasts: toasts) }
                action("Add Folder to Workspace…", "plus.rectangle.on.folder") { WorkspaceActions.addFolder(to: workspace, toasts: toasts) }
                if let openWorkspace { action("Open Workspace…", "folder", openWorkspace) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                action("Clone Repository…", "arrow.down.circle") { repoSheets?.active = .clone }
                action("New Repository…", "plus.circle") { repoSheets?.active = .newRepository }
            }
            let recents = workspace.app.config.recentWorkspaces.prefix(5)
            if let openRecent, !recents.isEmpty {
                Divider()
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recents), id: \.self) { path in
                        action(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, "clock") {
                            openRecent(URL(fileURLWithPath: path))
                        }
                        .help(path)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.brand)
    }
}
