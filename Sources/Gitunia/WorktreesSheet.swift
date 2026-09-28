import SwiftUI
import GituniaCore

struct WorktreesSheet: View {
    var store: RepositoryStore
    var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var worktrees: [Worktree]?
    @State private var error: String?
    @State private var isWorking = false
    @State private var showAddForm = false
    @State private var newBranch = ""
    @State private var newPath = ""
    @State private var createBranch = true
    /// Two-step like `PendingBranchVerb`: plain remove first, then "Remove Anyway" (`--force`)
    /// carrying git's refusal when the worktree has modified or untracked files.
    @State private var pendingRemove: (worktree: Worktree, refusal: String?)?

    init(store: RepositoryStore, workspace: WorkspaceStore, worktrees: [Worktree]? = nil) {
        self.store = store
        self.workspace = workspace
        _worktrees = State(initialValue: worktrees)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worktrees — \(store.repo.name)").font(.headline)
            Group {
                if let worktrees {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(worktrees.enumerated()), id: \.element.id) { index, wt in
                                row(wt, isMain: index == 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 320)
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            if showAddForm { addForm }
            if let error { SheetError(message: error) }
            HStack {
                if !showAddForm {
                    Button("Add Worktree…", systemImage: "plus") { showAddForm = true }
                }
                if worktrees?.contains(where: \.isPrunable) == true {
                    Button("Prune") { run { await store.pruneWorktrees() } }
                        .help("Forget worktrees whose folder no longer exists (git worktree prune)")
                }
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(showAddForm ? nil : .defaultAction)
            }
            .disabled(isWorking)
        }
        .padding(20)
        .frame(width: 540)
        .task {
            guard worktrees == nil else { return }
            await reload()
        }
        .confirmationDialog(pendingRemove?.refusal == nil ? "Remove this worktree?" : "Remove the worktree anyway?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible, presenting: pendingRemove) { pending in
            Button(pending.refusal == nil ? "Remove" : "Remove Anyway", role: .destructive) { remove(pending.worktree, force: pending.refusal != nil) }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { pending in
            if let refusal = pending.refusal {
                Text("Git refused: \(refusal)\nForcing deletes its uncommitted changes and untracked files.")
            } else {
                Text("Deletes the folder \(shortPath(pending.worktree.path)). Its branch is kept.")
            }
        }
    }

    /// `<repo-parent>/<repo>-<branch>`, slashes in the branch flattened to dashes.
    private var defaultNewPath: String {
        let branch = newBranch.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return store.url.deletingLastPathComponent()
            .appendingPathComponent("\(store.url.lastPathComponent)-\(branch.isEmpty ? "branch" : branch)").path
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Branch", text: $newBranch, prompt: Text("feature/x"))
            HStack {
                TextField("Folder", text: $newPath, prompt: Text(defaultNewPath))
                Button("Choose…") {
                    if let url = WorkspacePanels.chooseFolder(message: "Choose the folder for the new worktree", prompt: "Choose",
                                                              in: store.url.deletingLastPathComponent(), canCreateDirectories: true) {
                        newPath = url.path
                    }
                }
            }
            HStack {
                Toggle("Create new branch", isOn: $createBranch)
                Spacer()
                Button("Cancel") { showAddForm = false; error = nil }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reload() async {
        do { worktrees = try await store.worktrees() } catch { self.error = error.localizedDescription }
    }

    /// Runs a worktree op, shows its stderr (credentials redacted) and reloads the list. On success
    /// the sidebar picks up/drops the worktree's repo by rescanning the linked folder right away —
    /// FSEvents inside a removed worktree route to that worktree's own store, never to a rescan.
    private func run(_ op: @escaping () async -> GitError?, onSuccess: @escaping () -> Void = {}) {
        SheetActionRunner.run(busy: $isWorking, error: $error, op, onSuccess: {
            onSuccess()
            await workspace.rescanFolder(containing: store.url)
        }, then: reload)
    }

    private func add() {
        let raw = newPath.trimmingCharacters(in: .whitespaces)
        let path = URL(fileURLWithPath: raw.isEmpty ? defaultNewPath : (raw as NSString).expandingTildeInPath)
        run({ await store.addWorktree(path: path, branch: newBranch, createBranch: createBranch) }) {
            showAddForm = false
            newBranch = ""
            newPath = ""
        }
    }

    private func remove(_ wt: Worktree, force: Bool) {
        pendingRemove = nil
        isWorking = true
        error = nil
        Task {
            if let e = await store.removeWorktree(wt, force: force) {
                let msg = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                // git: "fatal: '<path>' contains modified or untracked files, use --force to delete it"
                if !force, msg.contains("--force") { pendingRemove = (wt, msg) } else { error = msg }
            } else {
                await workspace.rescanFolder(containing: store.url)
            }
            await reload()
            isWorking = false
        }
    }

    /// Relative to the repo's parent folder when inside it (git reports realpaths, so compare resolved).
    private func shortPath(_ path: String) -> String {
        // Foundation's resolvingSymlinksInPath strips `/private` only for paths that exist, while
        // git always reports `/private/var/…` — so a missing (prunable) worktree needs that form too.
        let ws = store.url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let roots = [ws, "/private" + ws].map { $0 + "/" }
        for p in [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] {
            if let root = roots.first(where: { p.hasPrefix($0) }) { return String(p.dropFirst(root.count)) }
        }
        return displayPath(path)
    }

    private func row(_ wt: Worktree, isMain: Bool) -> some View {
        let sidebarRepo = workspace.repository(atPath: wt.path)
        return HStack(spacing: 8) {
            Image(systemName: isMain ? "house" : "arrow.triangle.branch")
                .foregroundStyle(sidebarRepo?.id == store.id ? Theme.brand : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(shortPath(wt.path)).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .help(wt.path)
                HStack(spacing: 6) {
                    if let branch = wt.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    } else if wt.isDetached {
                        Text("detached \(wt.head.map { String($0.prefix(8)) } ?? "")")
                    } else if wt.isBare {
                        Text("bare")
                    }
                    if isMain { Badge(text: "main worktree") }
                    if let reason = wt.lockedReason { Badge(text: reason.isEmpty ? "locked" : "locked: \(reason)", systemImage: "lock") }
                    if wt.isPrunable { Badge(text: "missing — prunable", systemImage: "exclamationmark.triangle", tint: .red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let sidebarRepo, sidebarRepo.id != store.id {
                Button("Select") { workspace.select(sidebarRepo); dismiss() }
            }
            Button("Reveal", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)])
            }
            .labelStyle(.iconOnly)
            .help("Reveal in Finder")
            .disabled(wt.isPrunable)
            if !isMain && !wt.isPrunable { // a missing folder is cleaned up by Prune
                Button("Remove…") { pendingRemove = (wt, nil) }
                    .disabled(isWorking)
            }
        }
    }

    private struct Badge: View {
        let text: String
        var systemImage: String?
        var tint: Color = .secondary
        var body: some View {
            Group {
                if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
            }
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        }
    }
}
