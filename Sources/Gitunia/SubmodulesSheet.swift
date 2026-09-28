import SwiftUI
import GituniaCore

struct SubmodulesSheet: View {
    var store: RepositoryStore
    var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUpdate = false
    @State private var isUpdating = false
    @State private var error: String?
    /// Commit subjects by hash, for drifted rows' "recorded → checked out" line.
    @State private var subjects: [String: String] = [:]
    @State private var pendingRemove: Submodule?
    @State private var showAddForm = false
    @State private var newURL = ""
    @State private var newPath = ""
    @State private var newBranch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Submodules — \(store.repo.name)").font(.headline)
            Group {
                if store.submodules.isEmpty {
                    Text("No submodules.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.submodules) { row($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 280)
                }
            }
            .confirmationDialog("Remove submodule \(pendingRemove?.path ?? "")?",
                                isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                                titleVisibility: .visible, presenting: pendingRemove) { sub in
                Button("Remove", role: .destructive) { run { await store.removeSubmodule(sub.path) } }
                Button("Cancel", role: .cancel) { pendingRemove = nil }
            } message: { sub in
                Text("Three steps: git submodule deinit -f (empties the folder), git rm -f (stages removing it and its .gitmodules entry — commit to finish), then deletes .git/modules/\(sub.path), the submodule's local clone. Unpushed work inside it is lost.")
            }
            if showAddForm { addForm }
            if let error { SheetError(message: error) }
            HStack {
                if !showAddForm {
                    Button("Add Submodule…", systemImage: "plus") { showAddForm = true }
                }
                Button("Sync URLs") { run { await store.syncSubmodules() } }
                    .help("Copy .gitmodules URLs into each submodule's remote config (git submodule sync --recursive)")
                    .disabled(store.submodules.isEmpty)
                if isUpdating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update All…") { confirmUpdate = true }
                    .disabled(store.submodules.isEmpty)
            }
            .disabled(isUpdating)
        }
        .padding(20)
        .frame(width: 560)
        .task { await store.refreshSubmodules() }
        .task(id: store.submodules) { await loadSubjects() }
        .confirmationDialog("Update all submodules?", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Update All") { update() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.updateMessage(repoName: store.repo.name))
        }
    }

    private func row(_ sub: Submodule) -> some View {
        let url = store.url.appendingPathComponent(sub.path)
        let sidebarRepo = workspace.repository(atPath: url.path)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(sub.state))
                .foregroundStyle(sub.state == .current ? Color.secondary : Theme.brand)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sub.path).font(.system(.body, design: .monospaced))
                    Text(Self.label(sub.state))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .foregroundStyle(sub.state == .current ? Color.secondary : Theme.brand)
                        .background((sub.state == .current ? Color.secondary : Theme.brand).opacity(0.15), in: Capsule())
                }
                if let remote = sub.url {
                    Text(RepoURL.redactingCredentials(remote))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(detail(sub)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let sidebarRepo {
                Button("Open") { workspace.select(sidebarRepo); dismiss() }
            }
            Menu {
                if sub.state == .uninitialized {
                    Button("Init") { run { await store.initSubmodule(sub.path) } }
                } else {
                    Button("Update to Recorded") { run { await store.initSubmodule(sub.path) } }
                        .disabled(sub.state == .current)
                }
                if let branch = sub.branch {
                    Button("Update to Remote (\(branch))") { run { await store.submoduleUpdateToRemote(sub.path) } }
                }
                Divider()
                if sidebarRepo == nil {
                    Button("Open as Repository") { openAsRepository(url) }
                        .disabled(sub.state == .uninitialized)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                // A nested submodule (from --recursive) isn't recorded by this repository's own
                // index, so removal — which reads/rewrites *this* repo's .gitmodules — stays disabled;
                // it's removed from its parent submodule instead. Init/Update run fine nested
                // (RepositoryStore.submoduleLocation runs them from the parent's checkout).
                Button("Remove…", role: .destructive) { pendingRemove = sub }
                    .disabled(sub.recordedCommit == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// "recorded a1b2c3d 'Fix…' → checked out d4e5f6a 'Add…'" when they differ, else hash · describe · branch.
    private func detail(_ sub: Submodule) -> String {
        if let recorded = sub.recordedCommit, let checkedOut = sub.checkedOutCommit, recorded != checkedOut {
            func commit(_ hash: String) -> String {
                [String(hash.prefix(7)), subjects[hash].map { "'\($0)'" }].compactMap { $0 }.joined(separator: " ")
            }
            return "recorded \(commit(recorded)) → checked out \(commit(checkedOut))"
        }
        return [String(sub.commit.prefix(8)), sub.describe, sub.branch.map { "tracks \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func loadSubjects() async {
        for sub in store.submodules {
            guard let recorded = sub.recordedCommit, let checkedOut = sub.checkedOutCommit, recorded != checkedOut else { continue }
            for hash in [recorded, checkedOut] where subjects[hash] == nil {
                if let info = await store.commitInfoForSubmodule(sub.path, hash: hash) { subjects[hash] = info.subject }
            }
        }
    }

    private var defaultNewPath: String { RepoURL.defaultName(from: newURL) }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("URL", text: $newURL, prompt: Text("https://github.com/owner/lib.git"))
            TextField("Path", text: $newPath, prompt: Text(defaultNewPath.isEmpty ? "libs/lib" : defaultNewPath))
            TextField("Branch", text: $newBranch, prompt: Text("Optional — enables Update to Remote"))
            HStack {
                Spacer()
                Button("Cancel") { showAddForm = false; error = nil }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty || isUpdating)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func add() {
        let raw = newPath.trimmingCharacters(in: .whitespaces)
        let path = raw.isEmpty ? defaultNewPath : raw
        run({ await store.addSubmodule(url: newURL, path: path, branch: newBranch) }) {
            showAddForm = false
            newURL = ""
            newPath = ""
            newBranch = ""
        }
    }

    private func openAsRepository(_ url: URL) {
        Task {
            do {
                try await workspace.addRepository(url)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func run(_ op: @escaping () async -> GitError?, onSuccess: @escaping () -> Void = {}) {
        pendingRemove = nil
        SheetActionRunner.run(busy: $isUpdating, error: $error, op, onSuccess: onSuccess)
    }

    /// Update-all wording, shared with ⌘K's "Update Submodules…".
    static func updateMessage(repoName: String) -> String {
        "Runs git submodule update --init --recursive: each submodule is checked out at the commit \(repoName) records (detached HEAD), initializing any that aren't yet. A submodule moved to another commit (+) is moved back."
    }

    static func icon(_ state: Submodule.State) -> String {
        switch state {
        case .current: "checkmark.circle"
        case .uninitialized: "circle.dashed"
        case .outOfDate: "arrow.triangle.2.circlepath"
        case .conflict: "exclamationmark.triangle"
        }
    }

    static func label(_ state: Submodule.State) -> String {
        switch state {
        case .current: "Up to date"
        case .uninitialized: "Not initialized"
        case .outOfDate: "Different commit checked out"
        case .conflict: "Merge conflict"
        }
    }

    private func update() {
        run { await store.updateSubmodules() }
    }
}
