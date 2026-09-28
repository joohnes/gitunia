import SwiftUI
import GituniaCore

/// Linked folders, single repositories and excluded repositories — the parts of a workspace the
/// flat sidebar doesn't show. Nothing here touches the disk; it only edits the workspace file.
struct ManageWorkspaceSheet: View {
    var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage \(workspace.displayName)").font(.headline)
            List {
                Section("Folders") {
                    if workspace.file.folders.isEmpty { placeholder("No linked folders") }
                    ForEach(workspace.file.folders, id: \.path) { folder in
                        let missing = workspace.missingFolders.contains(folder.path)
                        row(path: folder.path,
                            detail: missing ? "Missing" : count(memberCount(folder)),
                            dimmed: missing) {
                            revealButton(folder.path)
                            Button("Unlink") { Task { await workspace.unlinkFolder(folder.path) } }
                        }
                    }
                }
                Section("Repositories") {
                    if workspace.file.repositories.isEmpty { placeholder("No single repositories") }
                    ForEach(workspace.file.repositories, id: \.self) { path in
                        let missing = workspace.missingPaths.contains(path)
                        row(path: path, detail: missing ? "Missing" : nil, dimmed: missing) {
                            revealButton(path)
                            Button("Remove") {
                                if let repo = workspace.repository(atPath: path) {
                                    WorkspaceActions.remove(repo, from: workspace, toasts: toasts)
                                } else {
                                    workspace.removeMissing(path)
                                }
                            }
                        }
                    }
                }
                Section("Excluded") {
                    let excluded = workspace.file.folders.flatMap { f in f.excluded.map { (id: f.path + "\u{0}" + $0, folder: f.path, relative: $0) } }
                    if excluded.isEmpty { placeholder("Nothing excluded") }
                    ForEach(excluded, id: \.id) { item in
                        row(path: WorkspaceMembership.absolute(item.relative, in: item.folder),
                            detail: "from \(URL(fileURLWithPath: item.folder).lastPathComponent)", dimmed: true) {
                            Button("Restore") { Task { await workspace.restoreExcluded(folder: item.folder, relative: item.relative) } }
                        }
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Button("Add Folder…") { WorkspaceActions.addFolder(to: workspace, toasts: toasts) }
                Button("Add Repos in Folder…") { WorkspaceActions.addReposInFolder(to: workspace, toasts: toasts) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The raw scan still lists excluded repos; the count shows what the folder actually contributes.
    private func memberCount(_ folder: WorkspaceFile.Folder) -> Int {
        let excluded = Set(folder.excluded.map { WorkspaceMembership.absolute($0, in: folder.path) })
        return (workspace.folderScans[folder.path] ?? []).filter { !excluded.contains($0) }.count
    }

    private func count(_ n: Int) -> String { "\(n) repositor\(n == 1 ? "y" : "ies")" }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func revealButton(_ path: String) -> some View {
        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: path)
            let target = FileManager.default.fileExists(atPath: path) ? url : url.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    private func row<Actions: View>(path: String, detail: String?, dimmed: Bool,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                Text(displayPath(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .opacity(dimmed ? 0.6 : 1)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            actions().buttonStyle(.borderless)
        }
        .help(path)
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
