import SwiftUI
import GituniaCore

/// "All Changes": every repository's uncommitted changes in one scrolling review, grouped
/// repository → file, with the diffs inline, next to a commit column for committing several
/// repositories at once (`WorkspaceCommitPanel`). Diffs load only as their file scrolls into view
/// (the stack is lazy) and are cached per `workingTreeVersion`, so a workspace with hundreds of
/// changed files opens instantly; after a write, the files in view reload in place.
struct WorkspaceChangesSheet: View {
    var workspace: WorkspaceStore
    /// Shows the file in the main window's Changes (and closes the sheet).
    var onOpenFile: (RepositoryStore, String) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var model = WorkspaceReviewModel()

    struct RepoGroup: Identifiable {
        let repo: RepositoryStore
        let shown: [FileChange]
        let hidden: Int
        var id: URL { repo.id }
    }

    /// Repositories with changes, by name, each with the filter applied. A repository the filter
    /// empties completely still shows (collapsed to its header) so its hidden count is visible.
    var groups: [RepoGroup] {
        workspace.repositories
            .filter { $0.repo.isAvailable && $0.repo.hasChanges }
            .filter { model.tag == nil || $0.repo.tags.contains(model.tag!) }
            .sorted { $0.repo.name.localizedCaseInsensitiveCompare($1.repo.name) == .orderedAscending }
            .map { repo in
                let result = model.filter.apply(Self.reviewOrder(repo))
                return RepoGroup(repo: repo, shown: result.shown, hidden: result.hidden)
            }
    }

    /// Conflicts first (they block everything else), then the Changes list's own section order.
    static func reviewOrder(_ repo: RepositoryStore) -> [FileChange] {
        repo.conflictedChanges + repo.stagedChanges.filter { $0.status != .conflicted }
            + repo.unstagedChanges + repo.untrackedChanges
    }

    var body: some View {
        let visible = groups
        VStack(spacing: 0) {
            filterBar(visible)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView("No uncommitted changes", systemImage: "checkmark.circle",
                                       description: Text("Every repository in this workspace is clean."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    WorkspaceDiffList(groups: visible, model: model, onOpenFile: open)
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    WorkspaceCommitPanel(workspace: workspace, repos: visible.map(\.repo), model: model)
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 560, maxHeight: .infinity)
                }
            }
            Divider()
            footer(visible)
        }
        .frame(minWidth: 860, idealWidth: 1240, maxWidth: .infinity, minHeight: 560, idealHeight: 780, maxHeight: .infinity)
    }

    private func open(_ repo: RepositoryStore, _ path: String) {
        dismiss()
        onOpenFile(repo, path)
    }

    // MARK: - Filter bar

    private func filterBar(_ groups: [RepoGroup]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField("Filter paths — e.g. “.swift !Tests”", text: $model.filter.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200, maxWidth: 320)
            ForEach(ChangeFilter.Kind.allCases, id: \.self) { kind in
                Toggle(kind.label, isOn: Binding(
                    get: { model.filter.kinds.contains(kind) },
                    set: { on in
                        if on { model.filter.kinds.insert(kind) } else { model.filter.kinds.remove(kind) }
                    }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
            }
            Toggle("Hide lockfiles & generated", isOn: $model.filter.hideNoise)
                .toggleStyle(.checkbox)
                .help("Lockfiles, minified bundles, source maps, snapshots and generated code")
            if !workspace.allTags.isEmpty {
                Picker("Tag", selection: $model.tag) {
                    Text("All tags").tag(String?.none)
                    ForEach(workspace.allTags, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            if !model.filter.isDefault || model.tag != nil {
                Button("Reset") { model.filter = ChangeFilter(); model.tag = nil }
                    .controlSize(.small)
            }
            Menu {
                Button("Expand All") { model.collapsedRepos = []; model.collapsedFiles = [] }
                Button("Collapse Files") {
                    model.collapsedFiles = Set(groups.flatMap { g in g.shown.map { model.key(g.repo, $0) } })
                }
                Button("Collapse Repositories") { model.collapsedRepos = Set(groups.map(\.id)) }
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Expand or collapse")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private func footer(_ groups: [RepoGroup]) -> some View {
        let files = groups.reduce(0) { $0 + $1.shown.count }
        let hidden = groups.reduce(0) { $0 + $1.hidden }
        return HStack {
            Text("\(groups.count) repositor\(groups.count == 1 ? "y" : "ies") · \(files) file\(files == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            if hidden > 0 {
                Text("· \(hidden) hidden by filters").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The sheet's view state, kept across re-renders: filters, what's collapsed, and loaded diffs.
@MainActor @Observable
final class WorkspaceReviewModel {
    var filter = ChangeFilter()
    var tag: String?
    var collapsedRepos: Set<URL> = []
    var collapsedFiles: Set<String> = []
    /// Files whose diff is shown past `previewLines`.
    var fullyExpanded: Set<String> = []

    // Commit column (`WorkspaceCommitPanel`).
    /// Checked repositories. Empty up front: which ones get committed is the user's call.
    var selected: Set<URL> = []
    var isCommitting = false
    var commitProgress: String?
    @ObservationIgnored var generateAllTask: Task<Void, Never>?

    /// The commit gate found something in at least one checked repository; waiting on the user.
    struct PendingGate {
        struct Entry { let repo: RepositoryStore; let report: CommitGate.Report }
        let reports: [Entry]
        /// Notes for repositories already left out (nothing to commit).
        let skipped: [String]
        let push: Bool
    }
    var pendingGate: PendingGate?

    struct Loaded { let version: Int; let diff: FileDiff? }
    private(set) var diffs: [String: Loaded] = [:]

    /// Lines shown per file before "Show all" — keeps one huge file from swamping the scroll.
    static let previewLines = 400

    func key(_ repo: RepositoryStore, _ change: FileChange) -> String { repo.id.path + "\u{0}" + change.id }

    /// The last loaded diff, even if the working tree has moved on since: `load` replaces it once
    /// the fresh one arrives. Showing nothing meanwhile collapsed every visible file of a repo to
    /// "Loading diff…" on each write an agent made, and the list jumped.
    func diff(_ repo: RepositoryStore, _ change: FileChange) -> Loaded? {
        diffs[key(repo, change)]
    }

    func load(_ repo: RepositoryStore, _ change: FileChange) async {
        let version = repo.workingTreeVersion
        let key = key(repo, change)
        if diffs[key]?.version == version { return }
        let diff = await repo.diff(for: change)
        guard !Task.isCancelled else { return }
        diffs[key] = Loaded(version: version, diff: diff)
    }
}

/// The lazy repository → file → line stack. Lines are direct children of the `LazyVStack` (not
/// nested in a per-file `VStack`), so only what is on screen is ever built.
private struct WorkspaceDiffList: View {
    let groups: [WorkspaceChangesSheet.RepoGroup]
    @Bindable var model: WorkspaceReviewModel
    var onOpenFile: (RepositoryStore, String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        if !model.collapsedRepos.contains(group.id) {
                            ForEach(group.shown) { change in
                                fileSection(change, in: group.repo)
                            }
                            if group.shown.isEmpty {
                                Text("All \(group.hidden) changed file\(group.hidden == 1 ? " is" : "s are") hidden by the filters.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                        }
                    } header: {
                        RepoHeader(group: group, isCollapsed: model.collapsedRepos.contains(group.id)) {
                            model.collapsedRepos.formSymmetricDifference([group.id])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ change: FileChange, in repo: RepositoryStore) -> some View {
        let key = model.key(repo, change)
        let collapsed = model.collapsedFiles.contains(key)
        FileHeader(
            change: change, repo: repo, isCollapsed: collapsed,
            toggle: { model.collapsedFiles.formSymmetricDifference([key]) },
            open: { onOpenFile(repo, change.path) }
        )
        // Keyed on the working-tree version so an agent's write reloads the diff in view.
        .task(id: "\(key)#\(repo.workingTreeVersion)#\(collapsed)") {
            guard !collapsed, change.status != .conflicted else { return }
            await model.load(repo, change)
        }
        if !collapsed {
            if change.status == .conflicted {
                // `git diff` on a conflicted path is a combined `diff --cc` (`@@@` hunks) that the
                // parser doesn't read; the main window shows the file with its conflict markers.
                HStack(spacing: 6) {
                    Text("Conflicted — resolve it in the main window.").foregroundStyle(.secondary)
                    Button("Show") { onOpenFile(repo, change.path) }.buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else if let loaded = model.diff(repo, change) {
                diffRows(loaded.diff, key: key, change: change)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading diff…").foregroundStyle(.secondary) }
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func diffRows(_ diff: FileDiff?, key: String, change: FileChange) -> some View {
        if let diff, !diff.isBinary, !diff.hunks.isEmpty {
            let full = model.fullyExpanded.contains(key)
            let limit = full ? Int.max : WorkspaceReviewModel.previewLines
            let (shown, total) = diff.truncated(toLines: limit)
            let ext = (change.path as NSString).pathExtension
            ForEach(Array(shown.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                HunkHeaderRow(text: hunk.header)
                    .id("\(key)#h\(hunkIndex)")
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line, fileExtension: ext)
                        .font(.system(.body, design: .monospaced))
                }
            }
            let shownLines = shown.hunks.reduce(0) { $0 + $1.lines.count }
            if !full && total > shownLines {
                Button("Show all \(total) lines") { model.fullyExpanded.insert(key) }
                    .buttonStyle(.link)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        } else {
            Text(diff?.isBinary == true ? "Binary file" : "No textual changes")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

private struct RepoHeader: View {
    let group: WorkspaceChangesSheet.RepoGroup
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            Image(systemName: "folder.fill").foregroundStyle(Theme.brand)
            Text(group.repo.repo.name).font(.headline)
            if let branch = group.repo.repo.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(group.shown.count) file\(group.shown.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if group.hidden > 0 {
                Text("+\(group.hidden) hidden").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            let unstaged = group.repo.unstagedChanges.count + group.repo.untrackedChanges.count
            if unstaged > 0 {
                Button("Stage All") { Task { await group.repo.stageAll() } }
                    .controlSize(.small)
                    .disabled(group.repo.isBusy || group.repo.needsAttention)
            }
            if !group.repo.stagedChanges.isEmpty {
                // Safe with conflicts present: `unstageAll()` then resets only the staged paths.
                Button("Unstage All") { Task { await group.repo.unstageAll() } }
                    .controlSize(.small)
                    .disabled(group.repo.isBusy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

private struct FileHeader: View {
    let change: FileChange
    let repo: RepositoryStore
    let isCollapsed: Bool
    let toggle: () -> Void
    let open: () -> Void

    private var statusLetter: String {
        switch change.status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            Text(statusLetter)
                .font(.caption.monospaced().bold())
                .frame(width: 14)
                .foregroundStyle(Theme.status(change.status))
            Text(change.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let old = change.oldPath {
                Text("← \(old)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(ChangeFilter.kind(of: change).label)
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            switch ChangeFilter.kind(of: change) {
            case .staged:
                Button("Unstage") { Task { await repo.unstage(change) } }
                    .controlSize(.small).disabled(repo.isBusy)
            case .unstaged, .untracked:
                Button("Stage") { Task { await repo.stage(change) } }
                    .controlSize(.small).disabled(repo.isBusy)
            case .conflicted:
                EmptyView()
            }
            Button(action: open) { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless)
                .help("Show in the main window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
