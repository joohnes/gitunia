import SwiftUI
import GituniaCore

/// T4 — Compare: content column half of the Changes | History | **Compare** tab. Base/head
/// pickers, a swap button, the "N ahead, M behind" summary, and the list of commits on `head` not
/// on `base` (`RepositoryStore.compareCommits`). Clicking a commit opens it in History
/// (`onOpenCommitInHistory`) rather than selecting it in place — Compare has no per-commit detail
/// of its own, only the combined range diff (`CompareDiffView`, the detail-column counterpart).
struct CompareView: View {
    var repo: RepositoryStore
    var workspace: WorkspaceStore
    /// Lifted to `ContentView` (like `HistoryView.fileHistoryPath`) so `CompareDiffView`, the
    /// detail-column sibling, can load the same range's combined diff. `nil` head means "the
    /// current branch" — resolved to a concrete name below, same convention as
    /// `HistoryView.selectedBranch`.
    @Binding var base: String?
    @Binding var head: String?
    var onOpenCommitInHistory: (CommitInfo) -> Void

    @State private var commits: [CommitInfo] = []
    @State private var counts: CompareCounts?
    @State private var isResolvingBase = false
    /// L3: true while the commits/counts `.task(id:)` below is in flight — distinct from
    /// `isResolvingBase` (the earlier "which branch is the base" step). Without this, a slow
    /// `compareCommits`/`compareCounts` call briefly shows "No commits ahead" before the real
    /// data arrives, same class of issue `HistoryView.isLoading` fixes for the history list.
    @State private var isLoadingCommits = false
    /// `git worktree list` — from a linked worktree it lists the main one and every sibling too.
    @State private var worktrees: [Worktree] = []
    @State private var loadedKey: String?

    private var resolvedHead: String { head ?? repo.repo.branch ?? "HEAD" }
    private var selectionKey: String { "\(repo.id)-\(base ?? "")-\(resolvedHead)" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: repo.id) {
            worktrees = (try? await repo.worktrees())?.filter { !$0.isBare && !$0.isPrunable } ?? []
            guard base == nil else { return }
            isResolvingBase = true
            base = await repo.baseBranch()
            isResolvingBase = false
        }
        .task(id: "\(selectionKey)-\(workspace.compareVersions(repo, base, resolvedHead))") {
            guard let base else { counts = nil; commits = []; return }
            // A worktree changed under the same selection: debounce, keep the old list meanwhile.
            if loadedKey == selectionKey {
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            }
            loadedKey = selectionKey
            isLoadingCommits = true
            defer { isLoadingCommits = false }
            let (b, h) = (CompareEndpoint(selection: base, worktrees: worktrees), CompareEndpoint(selection: resolvedHead, worktrees: worktrees))
            counts = await repo.compareCounts(base: b, head: h)
            commits = await repo.compareCommits(base: b, head: h)
        }
    }

    @ViewBuilder
    private var content: some View {
        if base == nil {
            if isResolvingBase {
                ContentUnavailableView("Resolving base branch…", systemImage: "arrow.left.arrow.right")
            } else {
                ContentUnavailableView {
                    Label("No base branch found", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Pick a base branch above to compare against.")
                }
            }
        } else if base == resolvedHead {
            ContentUnavailableView("Nothing to compare", systemImage: "checkmark.circle",
                                   description: Text("\(display(resolvedHead)) is the base itself."))
        } else if isLoadingCommits && commits.isEmpty {
            ProgressView()
        } else if commits.isEmpty {
            ContentUnavailableView("No commits ahead", systemImage: "checkmark.circle",
                                   description: Text("\(display(resolvedHead)) has no new commits since \(display(base ?? ""))."))
        } else {
            List(commits) { commit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(commit.shortHash).font(.caption.monospaced())
                        if repo.agentProfile.matches(author: commit.author, email: commit.authorEmail) { AgentGlyph() }
                        Text(commit.author)
                        Text(commit.date)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpenCommitInHistory(commit) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                branchPicker(
                    "Base",
                    selection: Binding(get: { base ?? "" }, set: { base = $0.isEmpty ? nil : $0; persistBase() })
                )
                Button {
                    swapBaseAndHead()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap base and head")
                .disabled(base == nil)
                branchPicker(
                    "Head",
                    selection: Binding(get: { resolvedHead }, set: { head = $0 == repo.repo.branch ? nil : $0 })
                )
            }
            if let counts {
                Text("\(counts.ahead) ahead, \(counts.behind) behind")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Local branches first, then remote — same popover list as `HistoryView.branchPicker`. An
    /// empty selection reads "Choose…" on the button (it was the picker's placeholder row).
    private func branchPicker(_ label: String, selection: Binding<String>) -> some View {
        // Session-only: `persistBase` skips these, the pref stays a branch name.
        let thisPath = repo.url.resolvingSymlinksInPath().path
        let worktreeRows = worktrees.count > 1 ? worktrees.map { wt in
            BranchListPopover<EmptyView>.Extra(
                value: CompareEndpoint.selection(for: wt),
                label: CompareEndpoint.label(for: wt) + (wt.path == thisPath ? " (this)" : "")
            )
        } : []
        let value = selection.wrappedValue
        return BranchPickerButton(
            title: value.isEmpty ? "Choose…" : worktreeRows.first { $0.value == value }?.label ?? value,
            branches: repo.branches,
            selection: value,
            trailing: ("Worktrees", worktreeRows),
            onPick: { selection.wrappedValue = $0 }
        )
        .help(label)
    }

    /// A worktree selection's label instead of its `worktree:<path>` tag.
    private func display(_ selection: String) -> String {
        CompareEndpoint(selection: selection, worktrees: worktrees).worktreeLabel ?? selection
    }

    private func persistBase() {
        guard base?.hasPrefix(CompareEndpoint.selectionPrefix) != true else { return }
        workspace.setCompareBase(base, for: repo)
    }

    private func swapBaseAndHead() {
        guard let currentBase = base else { return }
        let currentHead = resolvedHead
        base = currentHead
        head = currentBase == repo.repo.branch ? nil : currentBase
        persistBase()
    }
}

/// Detail-column counterpart to `CompareView`: the combined `base...head` change as a file list +
/// diff, reusing `FileDiffPane` (tree toggle, Wrap, Inline/Split, Open in Editor, Show File
/// History) — the same machinery `CommitDiffView` uses for a single commit. No "Restore…" item:
/// unlike a commit diff, a compare range has no single source commit to restore a file's content
/// from.
struct CompareDiffView: View {
    var workspace: WorkspaceStore
    var repo: RepositoryStore
    var base: String?
    var head: String?
    @Binding var selectedPath: String?
    var onRequestFileHistory: (String) -> Void = { _ in }

    @State private var files: [FileDiff] = []
    @AppStorage("diffMode") private var mode: DiffMode = .inline
    @AppStorage("diffWrap") private var wrap = false
    @AppStorage("compareView.treeMode") private var treeMode = true
    /// Worktree endpoints whose uncommitted changes the diff includes (`RepositoryStore.uncommittedLabels`).
    @State private var uncommittedLabels: [String] = []
    @State private var loadedKey: String?
    /// Bumped by the fallback watcher below.
    @State private var fallbackVersion = 0

    private var resolvedHead: String { head ?? repo.repo.branch ?? "HEAD" }
    private var selectionKey: String { "\(repo.id)-\(base ?? "")-\(resolvedHead)" }
    /// B9: the compared worktree's own path when `head` is a worktree endpoint (empty `worktrees` is
    /// fine — `contentRoot` only needs the path, not the label a full lookup would add).
    private var headContentRoot: URL? { CompareEndpoint(selection: resolvedHead, worktrees: []).contentRoot }

    var body: some View {
        VStack(spacing: 0) {
            if let base, base != resolvedHead {
                if !uncommittedLabels.isEmpty {
                    Label("Includes uncommitted changes in \(uncommittedLabels.joined(separator: " and "))", systemImage: "pencil.line")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                }
                FileDiffPane(
                    repo: repo, files: files, selectedPath: $selectedPath, mode: mode, wrap: wrap,
                    treeMode: $treeMode,
                    treeSalt: "compare-\(base)-\(resolvedHead)",
                    contentRoot: headContentRoot,
                    previewSource: previewSource,
                    onRequestFileHistory: onRequestFileHistory,
                    extraFileMenuItems: { (_: String) in EmptyView() },
                    workspace: workspace
                )
            } else {
                ContentUnavailableView("Nothing to compare", systemImage: "arrow.left.arrow.right")
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Diff mode", selection: $mode) {
                    ForEach(DiffMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                WrapToggle(isOn: $wrap)
            }
        }
        .task(id: "\(selectionKey)-\(workspace.compareVersions(repo, base, resolvedHead))-\(fallbackVersion)") {
            guard let base, base != resolvedHead else { files = []; selectedPath = nil; uncommittedLabels = []; return }
            // A worktree changed under the same selection: debounce, keep the old diff (and its
            // selected file, below) meanwhile.
            if loadedKey == selectionKey {
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            }
            loadedKey = selectionKey
            let worktrees = (try? await repo.worktrees()) ?? []
            let (b, h) = (CompareEndpoint(selection: base, worktrees: worktrees), CompareEndpoint(selection: resolvedHead, worktrees: worktrees))
            uncommittedLabels = RepositoryStore.uncommittedLabels(base: b, head: h)
            files = await repo.compareDiff(base: b, head: h)
            if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
                selectedPath = files.first?.path
            }
        }
        // Fallback for a worktree endpoint with no store in the workspace (nothing else watches it).
        // Watches both the worktree root (working-tree edits) and its real gitdir under the main
        // repo's `.git/worktrees/<name>/` (B9) — a commit made there doesn't touch the worktree root
        // at all, only that gitdir's HEAD/index/refs, which `WorkspaceStore.relevantPaths` already
        // recognizes (the `worktrees/<name>/HEAD` shape).
        .task(id: unwatchedWorktrees) {
            guard !unwatchedWorktrees.isEmpty else { return }
            let gitDirs = unwatchedWorktrees.compactMap { RepositoryStore.gitDir(forWorktree: URL(fileURLWithPath: $0))?.path }
            let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let watcher = FSEventsWatcher(paths: unwatchedWorktrees + gitDirs) { paths in
                if !WorkspaceStore.relevantPaths(paths).isEmpty { continuation.yield() }
            }
            watcher.start()
            defer { watcher.stop() }
            for await _ in events { fallbackVersion += 1 }
        }
    }

    /// `FileDiffPane.previewSource`: each side resolved the same way `compareDiff` itself does — a
    /// ref through `previewFile` (`git show`), a worktree endpoint as its file on disk directly
    /// (it has no commit of its own to `git show` from).
    private func previewSource(_ path: String) async -> (before: URL?, after: URL?) {
        guard let base else { return (nil, nil) }
        let worktrees = (try? await repo.worktrees()) ?? []
        let b = CompareEndpoint(selection: base, worktrees: worktrees)
        let h = CompareEndpoint(selection: resolvedHead, worktrees: worktrees)
        async let before = previewURL(for: b, path: path)
        async let after = previewURL(for: h, path: path)
        return await (before, after)
    }

    private func previewURL(for endpoint: CompareEndpoint, path: String) async -> URL? {
        switch endpoint {
        case .ref(let r):
            return await repo.previewFile(path: path, at: r)
        case .worktree(let wtPath, _):
            let fileURL = wtPath.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }
    }

    /// Worktree endpoints' paths that aren't a repository in the workspace.
    private var unwatchedWorktrees: [String] {
        [base, resolvedHead].compactMap { selection in
            guard let selection, selection.hasPrefix(CompareEndpoint.selectionPrefix) else { return nil }
            let path = String(selection.dropFirst(CompareEndpoint.selectionPrefix.count))
            return workspace.repository(atPath: path) == nil ? path : nil
        }
    }
}

extension WorkspaceStore {
    /// `workingTreeVersion`s a compare depends on — this repo's, plus each worktree endpoint's own
    /// store (0 for a branch or a worktree outside the workspace) — so its `.task(id:)` reruns
    /// when either side's tree changes.
    func compareVersions(_ repo: RepositoryStore, _ selections: String?...) -> [Int] {
        [repo.workingTreeVersion] + selections.map { selection in
            guard let selection, selection.hasPrefix(CompareEndpoint.selectionPrefix) else { return 0 }
            return repository(atPath: String(selection.dropFirst(CompareEndpoint.selectionPrefix.count)))?.workingTreeVersion ?? 0
        }
    }
}
