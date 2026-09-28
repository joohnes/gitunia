import SwiftUI
import GituniaCore

/// Where a new clone / repository goes unless the user picks elsewhere: the last place they used,
/// else the first linked folder (so it's picked up by that folder's scan), else home.
@MainActor
func defaultRepoParent(for workspace: WorkspaceStore) -> URL {
    if let last = workspace.app.config.lastRepoParent, FileManager.default.fileExists(atPath: last) {
        return URL(fileURLWithPath: last)
    }
    if let folder = workspace.file.folders.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return URL(fileURLWithPath: folder.path)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// "Location: ~/Projects  [Choose…]" row shared by both sheets.
private struct LocationRow: View {
    @Binding var parent: URL
    var body: some View {
        HStack {
            Text("Location:").foregroundStyle(.secondary)
            Text(displayPath(parent.path)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                if let url = WorkspacePanels.chooseFolder(message: "Choose where the repository folder is created", prompt: "Choose") {
                    parent = url
                }
            }
        }
        .font(.callout)
    }
}

struct CloneRepositorySheet: View {
    var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var url: String
    @State private var name: String
    @State private var nameEdited = false
    @State private var progress: CloneProgress?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var parent: URL
    @State private var options = CloneOptions()
    @State private var showOptions = false

    /// Initial values exist for the offscreen render tests; the app opens it empty.
    init(workspace: WorkspaceStore, url: String = "", progress: CloneProgress? = nil, error: String? = nil,
         parent: URL? = nil) {
        self.workspace = workspace
        _parent = State(initialValue: parent ?? defaultRepoParent(for: workspace))
        _url = State(initialValue: url)
        _name = State(initialValue: RepoURL.defaultName(from: url))
        _progress = State(initialValue: progress)
        _error = State(initialValue: error)
    }

    private var isRunning: Bool { task != nil || progress != nil }

    private var nameProblem: String? {
        guard !name.isEmpty else { return nil }
        return NewRepoName.validate(name, in: parent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Repository").font(.headline)
            TextField("Repository URL", text: $url, prompt: Text("https://github.com/owner/repo.git"))
                .onChange(of: url) { if !nameEdited { name = RepoURL.defaultName(from: url) } }
            TextField("Folder name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
            LocationRow(parent: $parent).disabled(isRunning)
            do {
                Text("Into \(displayPath(parent.appendingPathComponent(name.isEmpty ? "…" : name).path))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Options", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Partial clone (blobs on demand, --filter=blob:none)", isOn: $options.partial)
                    Toggle("Shallow (depth 1)", isOn: $options.shallow)
                    Toggle("Sparse checkout (start with only the root, pick folders after)", isOn: $options.sparse)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
            }
            .font(.callout)
            .disabled(isRunning)
            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(progress.phase)
                        Spacer()
                        if let p = progress.percent { Text("\(p)%").monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let p = progress.percent {
                        ProgressView(value: Double(p), total: 100)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            if let error { SheetError(message: error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if let task { task.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || url.trimmingCharacters(in: .whitespaces).isEmpty || name.isEmpty || nameProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isRunning)
    }

    private func start() {
        error = nil
        progress = CloneProgress(phase: "Starting")
        let source = url, folder = name, options = options
        task = Task {
            defer { task = nil; progress = nil }
            do {
                try await workspace.cloneRepository(from: source, named: folder, in: parent, options: options) { progress = $0 }
                toasts.post(.success("Cloned \(folder)"))
                dismiss()
            } catch is CancellationError {
                error = "Clone cancelled."
            } catch let e as GitError {
                error = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - New repository

struct NewRepositorySheet: View {
    var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var name: String
    @State private var error: String?
    @State private var isRunning = false
    @State private var parent: URL

    init(workspace: WorkspaceStore, name: String = "", parent: URL? = nil) {
        self.workspace = workspace
        _parent = State(initialValue: parent ?? defaultRepoParent(for: workspace))
        _name = State(initialValue: name)
    }


    private var nameProblem: String? {
        guard !name.isEmpty else { return nil }
        return NewRepoName.validate(name, in: parent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Repository").font(.headline)
            TextField("Folder name", text: $name)
            LocationRow(parent: $parent).disabled(isRunning)
            do {
                Text("Runs git init -b master in \(displayPath(parent.appendingPathComponent(name.isEmpty ? "…" : name).path)). No commit is made.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.red) }
            if let error { SheetError(message: error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    isRunning = true
                    Task {
                        defer { isRunning = false }
                        do {
                            try await workspace.initRepository(named: name, in: parent)
                            toasts.post(.success("Created \(name)"))
                            dismiss()
                        } catch let e as GitError {
                            error = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || name.isEmpty || nameProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
