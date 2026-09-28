import SwiftUI
import GituniaCore

/// ⌘K "Search in all repositories…": `git grep` over every working tree, or the pickaxe
/// (`git log -S`) over every history, results grouped by repository. Runs on submit (not per
/// keystroke — 40 repos × a git process each is too much to fire on every character).
struct WorkspaceSearchSheet: View {
    enum Mode: String, CaseIterable { case workingTree = "Working tree", commits = "Commits" }

    struct RepoResults: Identifiable {
        let repo: RepositoryStore
        var hits: [GrepHit] = []
        var commits: [CommitInfo] = []
        var id: URL { repo.id }
        var count: Int { hits.count + commits.count }
    }

    var workspace: WorkspaceStore
    var onOpenFile: (RepositoryStore, String) -> Void
    var onOpenCommit: (RepositoryStore, CommitInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var mode: Mode
    @State private var results: [RepoResults]
    /// The query last submitted — the search task is keyed on it (plus `mode`), so typing alone
    /// doesn't search and a new submit cancels the previous run.
    @State private var submitted = ""
    @State private var isSearching = false

    /// `query`/`mode`/`results` let the render test show a populated sheet without running git.
    init(workspace: WorkspaceStore, query: String = "", mode: Mode = .workingTree, results: [RepoResults] = [],
         onOpenFile: @escaping (RepositoryStore, String) -> Void = { _, _ in },
         onOpenCommit: @escaping (RepositoryStore, CommitInfo) -> Void = { _, _ in }) {
        self.workspace = workspace
        self.onOpenFile = onOpenFile
        self.onOpenCommit = onOpenCommit
        _query = State(initialValue: query)
        _mode = State(initialValue: mode)
        _results = State(initialValue: results)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(mode == .workingTree ? "Search files in every repository…" : "Find commits adding or removing…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitted = query.trimmingCharacters(in: .whitespaces) }
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { group in
                        LazyVStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(Theme.brand)
                                Text(group.repo.repo.name).font(.headline)
                                Text("\(group.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(group.hits, id: \.self) { hit in
                                resultRow(lead: "\(hit.path):\(hit.line)", text: hit.text) { open { onOpenFile(group.repo, hit.path) } }
                            }
                            ForEach(group.commits) { commit in
                                resultRow(lead: commit.shortHash, text: commit.subject) { open { onOpenCommit(group.repo, commit) } }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 360)
            .overlay {
                if isSearching && results.isEmpty { ProgressView() }
                else if results.isEmpty && !submitted.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
            HStack {
                if isSearching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task(id: "\(mode.rawValue)\u{0}\(submitted)") { await search() }
    }

    private func resultRow(lead: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lead).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(text.trimmingCharacters(in: .whitespaces)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
    }

    private func open(_ navigate: () -> Void) {
        dismiss()
        navigate()
    }

    /// Chunks of 8 repos in flight — same shape (and same `Task {}`-array reason) as
    /// `WorkspaceStore.refreshAll`. Results land progressively, chunk by chunk.
    private func search() async {
        let q = submitted, mode = mode
        guard !q.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        var out: [RepoResults] = []
        results = []
        let repos = workspace.repositories.filter(\.repo.isAvailable)
        for start in stride(from: 0, to: repos.count, by: 8) {
            let tasks = repos[start..<min(start + 8, repos.count)].map { repo in
                Task {
                    mode == .workingTree
                        ? RepoResults(repo: repo, hits: await repo.grep(q))
                        : RepoResults(repo: repo, commits: await repo.commitsTouching(q))
                }
            }
            for task in tasks {
                let r = await task.value
                if r.count > 0 { out.append(r) }
            }
            if Task.isCancelled { return }
            results = out
        }
    }
}
