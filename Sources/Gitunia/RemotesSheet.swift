import SwiftUI
import GituniaCore

/// Lists a repository's remotes and edits them: Add / Rename / Change URL / Remove, per-remote
/// Fetch, and the default remote (only offered with more than one). Every URL shown goes through
/// `URLRedaction` — a token in a remote URL never reaches the screen, and "Change URL…" starts
/// empty rather than pre-filled with the raw (possibly credentialed) URL.
struct RemotesSheet: View {
    enum EditorKind: Equatable {
        case add
        case rename(String)
        case changeURL(RemoteInfo)
        case remove(String, RemoteRemovalImpact)
    }

    struct EditorState: Equatable {
        var kind: EditorKind
        var name = ""
        var url = ""
        var problem: String?
    }

    let store: RepositoryStore
    let workspace: WorkspaceStore
    let toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var remotes: [RemoteInfo] = []
    @State private var editor: EditorState?
    @State private var isWorking = false

    init(store: RepositoryStore, workspace: WorkspaceStore, toasts: ToastCenter, initialEditor: EditorState? = nil) {
        self.store = store
        self.workspace = workspace
        self.toasts = toasts
        _editor = State(initialValue: initialEditor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Remotes — \(store.repo.name)").font(.title3.bold())
                Spacer()
                Button("Add…", systemImage: "plus") { editor = EditorState(kind: .add) }
                    .disabled(editor != nil)
            }

            if remotes.isEmpty {
                Text("No remotes configured. Add one to fetch and push.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(remotes) { remote in
                            row(remote)
                            if remote != remotes.last { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }

            if remotes.count > 1 {
                Picker("Default remote", selection: Binding(
                    get: { store.defaultRemote.flatMap { name in remotes.contains { $0.name == name } ? name : nil } },
                    set: { workspace.setDefaultRemote($0, for: store) }
                )) {
                    Text("None — upstream, else origin").tag(String?.none)
                    ForEach(remotes) { Text($0.name).tag(String?.some($0.name)) }
                }
                Text("Used by Fetch when the current branch has no upstream, and by the first Push of a new branch. Force push always goes to the branch's own upstream.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let editor { editorPanel(editor) }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(editor == nil ? .defaultAction : nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { remotes = await store.listRemotes() }
    }

    // MARK: - Rows

    private func row(_ remote: RemoteInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "network").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(remote.name).font(.body.bold())
                    if remotes.count > 1, store.defaultRemote == remote.name {
                        Text("Default")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.brand.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.brand)
                    }
                    if store.upstreamRemote == remote.name {
                        Text("upstream of \(store.repo.branch ?? "HEAD")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                urlLine(remote.pushURL == remote.fetchURL ? nil : "fetch", remote.fetchURL)
                if remote.pushURL != remote.fetchURL { urlLine("push", remote.pushURL) }
            }
            Spacer(minLength: 8)
            Menu {
                Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        let result = await store.fetch(from: remote.name)
                        toasts.post(Toast(remote: result, repo: store.repo.name))
                    }
                }
                .disabled(store.isBusy)
                Divider()
                Button("Rename…") { editor = EditorState(kind: .rename(remote.name), name: remote.name) }
                Button("Change URL…") { editor = EditorState(kind: .changeURL(remote)) }
                Divider()
                Button("Remove…", role: .destructive) {
                    Task {
                        let impact = await store.removalImpact(of: remote.name)
                        editor = EditorState(kind: .remove(remote.name, impact))
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(editor != nil)
            .help("More actions")
        }
        .padding(.vertical, 8)
    }

    private func urlLine(_ label: String?, _ url: String) -> some View {
        HStack(spacing: 4) {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
            Text(URLRedaction.redact(url))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Editor panel

    @ViewBuilder
    private func editorPanel(_ state: EditorState) -> some View {
        let binding = Binding(get: { editor ?? state }, set: { editor = $0 })
        VStack(alignment: .leading, spacing: 10) {
            switch state.kind {
            case .add:
                Text("Add Remote").font(.headline)
                TextField("Name (e.g. upstream)", text: binding.name)
                TextField("URL or path", text: binding.url)
            case .rename(let old):
                Text("Rename “\(old)”").font(.headline)
                TextField("New name", text: binding.name)
                Text("Its remote-tracking branches and every branch tracking it follow the new name. Nothing changes on the server.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .changeURL(let remote):
                Text("Change URL of “\(remote.name)”").font(.headline)
                TextField(URLRedaction.redact(remote.fetchURL), text: binding.url)
                Text("Current: \(URLRedaction.redact(remote.fetchURL))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            case .remove(let name, let impact):
                Label("Remove “\(name)”?", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red)
                Text(Self.removalMessage(name: name, impact: impact))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = state.problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editor = nil }
                    .keyboardShortcut(.cancelAction)
                if case .remove(let name, _) = state.kind {
                    Button("Remove \(name)", role: .destructive) { submit() }
                        .foregroundStyle(.red)
                        .disabled(isWorking)
                } else {
                    Button(state.kind == .add ? "Add" : "Save") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .tint(Theme.brand)
                        .disabled(isWorking)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Plain-language summary of what `git remote remove` takes with it (verified in
    /// `RemotesStoreTests.testRemoveReportsImpactThenDropsRefsAndUpstream`).
    static func removalMessage(name: String, impact: RemoteRemovalImpact) -> String {
        var lines = ["Removes the remote from this repository only — nothing on the server is deleted."]
        switch impact.trackingRefCount {
        case 0: break
        case 1: lines.append("1 remote-tracking branch (\(name)/…) disappears locally.")
        default: lines.append("\(impact.trackingRefCount) remote-tracking branches (\(name)/…) disappear locally.")
        }
        if !impact.trackingBranches.isEmpty {
            lines.append("These branches lose their upstream: \(impact.trackingBranches.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    private func submit() {
        guard let state = editor else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            let result: RemoteEditResult
            switch state.kind {
            case .add: result = await store.addRemote(name: state.name, url: state.url)
            case .rename(let old): result = await store.renameRemote(old, to: state.name)
            case .changeURL(let remote): result = await store.setRemoteURL(remote.name, to: state.url)
            case .remove(let name, _): result = await store.removeRemote(name)
            }
            switch result {
            case .succeeded:
                if case .rename(let old) = state.kind, store.defaultRemote == old {
                    workspace.setDefaultRemote(state.name.trimmingCharacters(in: .whitespacesAndNewlines), for: store)
                }
                if case .remove(let name, _) = state.kind, store.defaultRemote == name {
                    workspace.setDefaultRemote(nil, for: store)
                }
                editor = nil
                remotes = await store.listRemotes()
            case .invalid(let message), .failed(let message):
                editor?.problem = message
            }
        }
    }
}

/// Branch menu items: Set Upstream (remote branches grouped per remote) and Unset Upstream.
struct UpstreamMenuItems: View {
    let repo: RepositoryStore
    let toasts: ToastCenter

    var body: some View {
        let remoteBranches = repo.branches.filter(\.isRemote)
        let groups = Dictionary(grouping: remoteBranches) { RemoteSelection.remote(ofTrackingBranch: $0.name, remotes: repo.remoteNames) }
        let isDetached = repo.repo.branch == nil || repo.repo.branch == "(detached)"
        Menu("Set Upstream", systemImage: "arrow.up.arrow.down") {
            if remoteBranches.isEmpty {
                Text("No remote branches — fetch first")
            } else if groups.count == 1 {
                ForEach(remoteBranches) { upstreamButton($0) }
            } else {
                ForEach(groups.keys.sorted(), id: \.self) { remote in
                    Section(remote) { ForEach(groups[remote] ?? []) { upstreamButton($0) } }
                }
            }
        }
        .disabled(isDetached)
        Button("Unset Upstream") { Task { await Self.unset(repo: repo, toasts: toasts) } }
        .disabled(isDetached || !repo.hasUpstream)
    }

    private func upstreamButton(_ branch: BranchInfo) -> some View {
        Button(branch.name) { Task { await Self.set(branch.name, repo: repo, toasts: toasts) } }
    }

    /// Shared with ⌘K. Failure is toasted by ContentView's generic `lastError` watcher.
    static func set(_ remoteBranch: String, repo: RepositoryStore, toasts: ToastCenter) async {
        if await repo.setUpstream(to: remoteBranch) {
            toasts.post(.success("Upstream set to \(remoteBranch)", detail: "\(repo.repo.name) · \(repo.repo.branch ?? "")"))
        }
    }

    static func unset(repo: RepositoryStore, toasts: ToastCenter) async {
        if await repo.unsetUpstream() {
            toasts.post(.success("Upstream unset", detail: "\(repo.repo.name) · \(repo.repo.branch ?? "")"))
        }
    }
}

/// "Fetch From" submenu: one item per remote (`RepositoryStore.remoteNames`, loaded on selection).
struct FetchFromMenu: View {
    let repo: RepositoryStore
    let toasts: ToastCenter

    var body: some View {
        Menu("Fetch From", systemImage: "arrow.triangle.2.circlepath") {
            ForEach(repo.remoteNames, id: \.self) { remote in
                Button(remote) {
                    Task {
                        let result = await repo.fetch(from: remote)
                        toasts.post(Toast(remote: result, repo: repo.repo.name))
                    }
                }
            }
        }
        .disabled(repo.isBusy || repo.remoteNames.isEmpty)
    }
}
