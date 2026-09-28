import SwiftUI
import GituniaCore

/// The file-list + diff pane shared by `CommitDiffView` (one commit) and `CompareView` (a base/head
/// range): tree/flat toggle, the selected file's diff, "Open in Editor" and "Show File History" in
/// every file's context menu. `extraFileMenuItems` carries what only one host offers (restoring a
/// version needs a single source commit, which a range doesn't have).
struct FileDiffPane<ExtraMenuItems: View>: View {
    var repo: RepositoryStore
    var files: [FileDiff]
    @Binding var selectedPath: String?
    var mode: DiffMode
    var wrap: Bool
    @Binding var treeMode: Bool
    /// Salts `FileTree.build`'s directory ids — must be unique per logical tree shape (see
    /// `FileTree.renderID`'s doc comment / `CommitDiffTreeRenderTests`) so two different diffs
    /// hosted by the same view identity never share a directory row's cached geometry.
    var treeSalt: String
    /// Working directory "Open in Editor" resolves `path` against — the compared worktree when the
    /// host is Compare on a worktree endpoint (B9), else nil to fall back to `repo.url`. File history
    /// always stays on the repo (same git history, `onRequestFileHistory` below), only opened rooted
    /// at this directory when the caller passes one.
    var contentRoot: URL? = nil
    /// Resolves a selected file's before/after preview URLs for `FilePreviewView` — `CommitDiffView`
    /// (a single commit's `<hash>^`/`<hash>`) and `CompareDiffView` (base/head refs, or a worktree
    /// endpoint's path directly) each know how to do this; other/test callers default to "no
    /// preview", which falls back to the existing "Binary file" placeholder.
    var previewSource: (String) async -> (before: URL?, after: URL?) = { _ in (nil, nil) }
    var onRequestFileHistory: (String) -> Void = { _ in }
    @ViewBuilder var extraFileMenuItems: (String) -> ExtraMenuItems

    @Environment(ToastCenter.self) private var toasts
    @Environment(EditorOpenCoordinator.self) private var editorRequests
    var workspace: WorkspaceStore

    /// Owned by the user's drag, not by layout: an `HSplitView` re-derived the divider from its
    /// children's ideal widths whenever the diff changed, so clicking another file resized the list.
    @AppStorage("fileDiffPane.listWidth") private var listWidth: Double = 200
    @State private var dragStartWidth: Double?
    /// Collapsed directory ids (`FileTreeNode.id`, stable across commits); absence means expanded.
    @State private var collapsedDirectories: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            // A single-file change doesn't need a file list — the diff gets the full width.
            if files.count > 1 {
                fileList.frame(width: listWidth)
                resizeHandle
            }
            diffPane
        }
    }

    private var resizeHandle: some View {
        Divider()
            .overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? listWidth
                                dragStartWidth = start
                                listWidth = min(max(start + value.translation.width, 140), 480)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }

    private var diffPane: some View {
        Group {
            if let file = files.first(where: { $0.path == selectedPath }) {
                if file.isBinary {
                    binaryPane(file)
                } else {
                    // Keyed on the path, not the `FileDiff` (which changes on a content refresh):
                    // a real file switch rebuilds the ScrollView, resetting its scroll offset.
                    DiffBodyView(diff: file, mode: mode, fileExtension: (file.path as NSString).pathExtension, wrap: wrap)
                        .id(file.path)
                }
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A binary file's preview — `FilePreviewView` once `previewSource` resolves its before/after
    /// URLs (nil/nil, the default for a caller with no preview source, falls straight through to
    /// the existing "Binary file" placeholder).
    private func binaryPane(_ file: FileDiff) -> some View {
        BinaryPreviewPane(repo: repo, path: file.path, previewSource: previewSource)
            .id(file.path)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            Group {
                if treeMode {
                    List(selection: $selectedPath) {
                        let tree = FileTree.build(from: files, path: \.path, salt: treeSalt)
                        ForEach(FileTree.flatten(tree, collapsed: collapsedDirectories)) { row in
                            treeRow(row)
                        }
                    }
                } else {
                    List(files, id: \.path, selection: $selectedPath) { file in
                        Text(file.path).lineLimit(1).tag(file.path)
                            .contextMenu { fileContextMenu(file.path) }
                    }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack {
            Text("Files").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TreeModeToggle(treeMode: $treeMode)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder
    private func treeRow(_ row: FileTreeRow<FileDiff>) -> some View {
        switch row.kind {
        case .directory:
            FileTreeRowView(row: row, onToggle: toggleCollapsed) { _, name in
                Text(name).lineLimit(1)
            }
        case .file(let file, _):
            FileTreeRowView(row: row, onToggle: toggleCollapsed) { _, name in
                Text(name).lineLimit(1)
            }
            .tag(file.path)
            .contextMenu { fileContextMenu(file.path) }
        }
    }

    private func toggleCollapsed(_ id: String) {
        if !collapsedDirectories.insert(id).inserted { collapsedDirectories.remove(id) }
    }

    /// Opens `path`'s *current* working-tree copy, not the version as it stood in this diff.
    @ViewBuilder
    private func openInEditorMenuItem(_ path: String) -> some View {
        Button("Open in Editor", systemImage: "square.and.pencil") {
            editorRequests.openWorkingTreeFile(
                path, in: contentRoot ?? repo.url,
                configuredBundleID: workspace.config.settings.editorBundleID, toasts: toasts
            )
        }
    }

    @ViewBuilder
    private func fileContextMenu(_ path: String) -> some View {
        openInEditorMenuItem(path)
        Button("Show File History", systemImage: "clock") { onRequestFileHistory(path) }
        extraFileMenuItems(path)
    }
}

/// Resolves `previewSource(path)` once per file, then shows `FilePreviewView` (or the plain
/// "Binary file" placeholder for `PreviewKind.none`/an unresolved source).
private struct BinaryPreviewPane: View {
    var repo: RepositoryStore
    var path: String
    var previewSource: (String) async -> (before: URL?, after: URL?)

    @State private var before: URL?
    @State private var after: URL?
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if before == nil && after == nil {
                // No preview source wired (a caller that hasn't adopted `previewSource` yet), or
                // neither side actually resolved — falls back to the plain placeholder rather than
                // an empty-looking preview pane.
                ContentUnavailableView("Binary file", systemImage: "doc.zipper")
            } else {
                FilePreviewView(repo: repo, path: path, kind: PreviewKind.kind(for: path), before: before, after: after)
            }
        }
        .task(id: path) {
            loaded = false
            (before, after) = await previewSource(path)
            loaded = true
        }
    }
}

/// The flat-list / tree segmented toggle above a file list.
struct TreeModeToggle: View {
    @Binding var treeMode: Bool

    var body: some View {
        Picker("View", selection: $treeMode) {
            Image(systemName: "list.bullet").tag(false).accessibilityLabel("Flat List")
            Image(systemName: "folder").tag(true).accessibilityLabel("Tree View")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(treeMode ? "Switch to flat list" : "Switch to tree view")
    }
}
