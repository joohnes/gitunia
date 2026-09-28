import SwiftUI
import GituniaCore

struct CommitDiffView: View {
    var workspace: WorkspaceStore
    var repo: RepositoryStore
    var commit: CommitInfo
    /// Published up to `ContentView` (not private `@State`) so ⌘⇧O can reach whichever file is
    /// selected here — same pattern as `ChangesView.selectedChange`. See `ContentView.editorTarget`.
    @Binding var selectedPath: String?
    /// `HistoryView`'s selection — clicking a parent hash in the header jumps straight to that
    /// commit (see `selectParent`) rather than trying to scroll/load `HistoryView`'s own paged
    /// list until it appears there: simpler, and works even when the parent isn't in any loaded
    /// page yet.
    @Binding var selection: CommitInfo?
    /// When set (file-history mode — see `HistoryView.fileHistorySelectedPath`), the file list
    /// preselects this path instead of the first file, if this commit's diff actually contains it.
    var preselectPath: String?
    /// "Show File History" on a file in this commit's list — routes back up to `ContentView`,
    /// same "hand the target up" shape as `EditorOpenCoordinator`.
    var onRequestFileHistory: (String) -> Void = { _ in }
    @Environment(ToastCenter.self) private var toasts
    @State private var files: [FileDiff] = []
    @State private var detail: CommitDetail?
    /// Per-file A/M/D/R status for this commit — `nil` for a path this commit didn't touch (never
    /// happens for a path actually in `files`, but a missing entry is treated as "don't know" and
    /// so restoring "before" stays disabled rather than risk the silent-delete case documented on
    /// `RepositoryStore.restoreFile`).
    @State private var fileStatuses: [String: FileHistoryChangeKind] = [:]
    @State private var pendingRestore: PendingRestore?
    /// 1-based parent index for a merge commit's "Diff against" picker — reset to 1 whenever the
    /// selected commit changes (see the `commit.hash`-keyed task below).
    @State private var selectedParentIndex = 1
    @State private var bodyExpanded = false
    @AppStorage("diffMode") private var mode: DiffMode = .inline
    // Same key as `DiffView` — one Wrap preference drives both views.
    @AppStorage("diffWrap") private var wrap = false
    /// Its own key, not `ChangesView.treeMode`: that list is short and flat by default, this one
    /// is often long, so a tree is the better default here.
    @AppStorage("historyView.treeMode") private var treeMode = true

    /// Body text past this length collapses behind "Show more" — the header is meant to orient,
    /// not to replace reading the full message in a terminal/editor.
    private static let bodyCollapseThreshold = 400

    var body: some View {
        VStack(spacing: 0) {
            commitHeader
            Divider()
            FileDiffPane(
                repo: repo, files: files, selectedPath: $selectedPath, mode: mode, wrap: wrap,
                treeMode: $treeMode,
                // Constant, not per-commit: directory ids must survive commit switches so collapse
                // state does; `FileTree.renderID` is what keeps row geometry fresh.
                treeSalt: "history",
                previewSource: previewSource,
                onRequestFileHistory: onRequestFileHistory,
                extraFileMenuItems: { path in
                    Divider()
                    Button("Restore This Version…", systemImage: "arrow.uturn.backward") {
                        pendingRestore = PendingRestore(path: path, target: .thisCommit(commit))
                    }
                    Button("Restore Version Before This Commit…", systemImage: "arrow.uturn.backward.circle") {
                        pendingRestore = PendingRestore(path: path, target: .beforeCommit(commit))
                    }
                    .disabled(fileStatuses[path] == nil || fileStatuses[path] == .added)
                    .help(fileStatuses[path] != .added ? "" : "This file didn't exist before this commit")
                },
                workspace: workspace
            )
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
        .task(id: commit.hash) {
            detail = await repo.commitDetail(commit.hash)
            selectedParentIndex = 1
            bodyExpanded = false
        }
        .task(id: "\(commit.hash)|\(selectedParentIndex)") {
            let parent = commit.parentCount > 1 ? selectedParentIndex : nil
            files = await repo.commitDiff(commit.hash, parent: parent)
            fileStatuses = await repo.commitFileStatuses(commit.hash, parent: parent)
            // File-history mode preselects its file under the path it had in *this* commit; no
            // match (e.g. a merge diffed against the other parent) falls back to the first file.
            if let preselectPath, files.contains(where: { $0.path == preselectPath }) {
                selectedPath = preselectPath
            } else {
                selectedPath = files.first?.path
            }
        }
        .confirmationDialog(
            pendingRestore.map(RestoreFileRunner.confirmTitle) ?? "Restore file?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let pending = pendingRestore { Task { await RestoreFileRunner.perform(pending, on: repo, toasts: toasts) } }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text(pendingRestore.map {
                RestoreFileRunner.confirmMessage(for: $0, hasUncommittedChanges: RestoreFileConfirmation.hasUncommittedChanges(path: $0.path, in: repo.repo.changes))
            } ?? "")
        }
    }

    /// Full message, author/committer identity, parents and hash — fetched once per commit via
    /// `RepositoryStore.commitDetail`. Falls back to `CommitInfo`'s subject and short hash while
    /// that fetch is in flight, so the header never looks empty.
    private var commitHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(commit.shortHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if commit.parentCount > 1 { parentPicker }
            }
            messageBlock
            identityBlock
            if let detail, !detail.parents.isEmpty { parentsRow(detail) }
            hashRow
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private var messageBlock: some View {
        let subject = detail?.subject ?? commit.subject
        let body = detail?.body ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Text(subject).font(.headline).textSelection(.enabled)
            if !body.isEmpty {
                let isLong = body.count > Self.bodyCollapseThreshold
                Text(isLong && !bodyExpanded ? String(body.prefix(Self.bodyCollapseThreshold)) + "…" : body)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if isLong {
                    Button(bodyExpanded ? "Show Less" : "Show More") { bodyExpanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                        .foregroundStyle(Theme.brand)
                }
            }
        }
    }

    @ViewBuilder
    private var identityBlock: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(detail.authorName) <\(detail.authorEmail)> — \(Self.readable(detail.authorDate))")
                    .help(Self.absolute(detail.authorDate))
                if detail.committerDiffersFromAuthor {
                    Text("Committed by \(detail.committerName) <\(detail.committerEmail)> — \(Self.readable(detail.committerDate))")
                        .help(Self.absolute(detail.committerDate))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// `--date=iso-strict` → "3 days ago" (raw text if it ever fails to parse).
    static func readable(_ iso: String) -> String { RelativeDate.parseISO(iso).map { RelativeDate.string(for: $0) } ?? iso }
    static func absolute(_ iso: String) -> String { RelativeDate.parseISO(iso).map(RelativeDate.absolute) ?? iso }

    private func parentsRow(_ detail: CommitDetail) -> some View {
        HStack(spacing: 4) {
            Text(detail.parents.count > 1 ? "Parents:" : "Parent:")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(zip(detail.parents, detail.parentsShort)), id: \.0) { full, short in
                Button(short) { selectParent(full) }
                    .buttonStyle(.link)
                    // `.link` ignores `.tint(_:)` (still draws system blue); `.foregroundStyle`
                    // is what overrides it.
                    .foregroundStyle(Theme.brand)
                    .font(.caption.monospaced())
            }
        }
    }

    private var hashRow: some View {
        HStack(spacing: 6) {
            Text(commit.hash).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy full hash")
        }
    }

    /// Merge commits only (`commit.parentCount > 1`) — which parent `commitDiff` diffs against.
    /// Defaults to parent 1, the existing first-parent behavior.
    private var parentPicker: some View {
        HStack(spacing: 4) {
            Text("Diff against:").font(.caption).foregroundStyle(.secondary)
            Picker("Diff against", selection: $selectedParentIndex) {
                ForEach(1...commit.parentCount, id: \.self) { i in
                    Text("parent \(i)").tag(i)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    /// `FileDiffPane.previewSource`: the parent side is whichever parent `commitDiff` is currently
    /// diffed against (`<hash>^N` for a merge's picked parent, `<hash>^` — first parent —
    /// otherwise), the other side is the commit itself.
    private func previewSource(_ path: String) async -> (before: URL?, after: URL?) {
        let parentRef = commit.parentCount > 1 ? "\(commit.hash)^\(selectedParentIndex)" : "\(commit.hash)^"
        async let before = repo.previewFile(path: path, at: parentRef)
        async let after = repo.previewFile(path: path, at: commit.hash)
        return await (before, after)
    }

    /// Jumps `HistoryView`'s selection to the clicked parent — fetched fresh by hash rather than
    /// looked up in `HistoryView`'s (separately paged) commit list, so this works whether or not
    /// the parent happens to already be loaded there.
    private func selectParent(_ hash: String) {
        Task {
            if let info = await repo.commitInfo(hash) {
                selection = info
            }
        }
    }

}
