import SwiftUI
import GituniaCore

/// The sheet's content, split out from `CleanPreviewSheet` so the offscreen render can instantiate
/// it with plain values — a `.sheet` never composites offscreen, only its content view does.
struct CleanPreviewSheetContent: View {
    @Binding var includeDirectories: Bool
    let files: [String]
    let isLoading: Bool
    var onCancel: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Untracked Files").font(.headline)
            Text("These files are not tracked by git — deleting them here can't be undone by git.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Include untracked directories", isOn: $includeDirectories)
            Divider()
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                } else if files.isEmpty {
                    Text("Nothing to delete.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(files, id: \.self) { path in
                                let isDirectory = path.hasSuffix("/")
                                HStack(spacing: 6) {
                                    Image(systemName: isDirectory ? "folder" : "doc")
                                        .foregroundStyle(.secondary).frame(width: 16)
                                    Text(path).font(.system(.body, design: .monospaced)).lineLimit(1)
                                    if isDirectory {
                                        Text("whole folder").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 240)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(Self.deleteTitle(for: files), role: .destructive, action: onDelete)
                    .foregroundStyle(.red)
                    .disabled(files.isEmpty || isLoading)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// "Files" only when every entry is a file — a `dir/` entry deletes a whole folder, so the count
    /// is of items, not files.
    static func countLabel(for paths: [String]) -> String {
        let noun = paths.contains { $0.hasSuffix("/") } ? "Item" : "File"
        return "\(paths.count) \(noun)\(paths.count == 1 ? "" : "s")"
    }

    static func deleteTitle(for paths: [String]) -> String { "Delete " + countLabel(for: paths) }
}

/// Owns the preview state: loads `RepositoryStore.cleanPreview` on appear and again
/// whenever the directories toggle changes, then deletes exactly that same list on confirm —
/// never a fresh `clean -n` lookup at delete time, so a file an agent writes while the sheet is up
/// is never swept up along with what the user actually saw and confirmed.
struct CleanPreviewSheet: View {
    var repo: RepositoryStore
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var includeDirectories = false
    @State private var files: [String] = []
    @State private var isLoading = true

    var body: some View {
        CleanPreviewSheetContent(
            includeDirectories: $includeDirectories,
            files: files,
            isLoading: isLoading,
            onCancel: { dismiss() },
            onDelete: deleteAndDismiss
        )
        .task(id: includeDirectories) {
            isLoading = true
            let preview = await repo.cleanPreview(includeDirectories: includeDirectories)
            // A toggle flipped mid-load cancels this task; its late result must not replace the
            // newer preview (the list shown is exactly what gets deleted).
            guard !Task.isCancelled else { return }
            files = preview
            isLoading = false
        }
    }

    private func deleteAndDismiss() {
        let paths = files
        let dirs = includeDirectories
        Task {
            let ok = await repo.clean(paths: paths, includeDirectories: dirs)
            if ok {
                toasts.post(.success(repo.repo.name, detail: "Deleted \(CleanPreviewSheetContent.countLabel(for: paths).lowercased()) (untracked)"))
            }
        }
        dismiss()
    }
}
