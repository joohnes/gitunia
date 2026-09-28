import SwiftUI
import GituniaCore

/// "Remove from Git…": stop tracking (file stays) or delete, optionally adding the paths to
/// `.gitignore`. Only stages the removal. Opened from the Changes context menu and ⌘K, via `RepoSheets`.
struct RemoveFromGitSheet: View {
    let repo: RepositoryStore
    let paths: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var keepOnDisk = true
    @State private var ignore = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove from Git — \(repo.repo.name)").font(.title3.bold())
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths.prefix(8), id: \.self) { Text($0).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
                if paths.count > 8 { Text("and \(paths.count - 8) more").font(.caption).foregroundStyle(.secondary) }
            }
            Picker("", selection: $keepOnDisk) {
                Text("Stop tracking — keep the files on disk").tag(true)
                Text("Delete from disk too").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Toggle("Add to .gitignore", isOn: $ignore)
            Text(keepOnDisk
                 ? "The removal is staged — commit it to take the files out of the repository."
                 : "The deletion is staged. Files with uncommitted edits are refused; committed versions stay in history.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { SheetError(message: error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(keepOnDisk ? "Stop Tracking" : "Delete", role: keepOnDisk ? nil : .destructive, action: remove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || repo.isBusy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func remove() {
        SheetActionRunner.run(busy: $busy, error: $error) {
            await repo.removeFromGit(paths, keepOnDisk: keepOnDisk, ignore: ignore)
        } onSuccess: {
            let what = paths.count == 1 ? paths[0] : "\(paths.count) paths"
            toasts?.post(.success(keepOnDisk ? "Stopped tracking \(what)" : "Deleted \(what)", detail: repo.repo.name))
            dismiss()
        }
    }
}
