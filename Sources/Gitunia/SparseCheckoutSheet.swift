import SwiftUI
import GituniaCore

/// "Sparse Checkout…" — pick which folders of a monorepo are on disk (cone mode). The tree is read
/// from HEAD, not the disk, so excluded folders are listed too; subfolders load on expand.
struct SparseCheckoutSheet: View {
    var repo: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    /// `nil` = not loaded yet.
    @State private var state: SparseState?
    /// Subfolder names per folder path ("" = root); a missing key = not loaded yet.
    @State private var tree: [String: [String]]
    @State private var expanded: Set<String>
    /// Checked folders (cone: each includes its whole subtree).
    @State private var selected: Set<String>
    @State private var errorText: String?
    @State private var isRunning = false

    /// `state`/`tree` preload the sheet (render tests); otherwise both are loaded on appear.
    init(repo: RepositoryStore, state: SparseState? = nil, tree: [String: [String]] = [:], expanded: Set<String> = []) {
        self.repo = repo
        _state = State(initialValue: state)
        _tree = State(initialValue: tree)
        _expanded = State(initialValue: expanded)
        _selected = State(initialValue: state.map(Self.initialSelection) ?? [])
    }

    enum CheckState: Equatable {
        case on, inherited, partial, off
        var icon: String {
            switch self {
            case .on, .inherited: "checkmark.square.fill"
            case .partial: "minus.square.fill"
            case .off: "square"
            }
        }
        var help: String {
            switch self {
            case .on: "Included with everything inside it"
            case .inherited: "Included because a parent folder is checked"
            case .partial: "Some subfolders are included"
            case .off: "Not checked out"
            }
        }
    }

    /// `inherited` = an ancestor is checked (cone takes the subtree); `partial` = some descendant is.
    static func checkState(_ path: String, selected: Set<String>) -> CheckState {
        if selected.contains(path) { return .on }
        if selected.contains(where: { path.hasPrefix($0 + "/") }) { return .inherited }
        if selected.contains(where: { $0.hasPrefix(path + "/") }) { return .partial }
        return .off
    }

    static func initialSelection(_ state: SparseState) -> Set<String> {
        state.enabled && state.cone ? Set(state.patterns) : []
    }

    static func statusLine(_ state: SparseState) -> String {
        guard state.enabled else { return "Off — full checkout" }
        guard state.cone else { return "Sparse checkout on, non-cone patterns" }
        let n = state.patterns.count
        return n == 0 ? "Sparse checkout on, cone mode, root files only"
            : "Sparse checkout on, cone mode, \(n) folder\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sparse Checkout — \(repo.repo.name)").font(.headline)
            if let state {
                Label(Self.statusLine(state), systemImage: state.enabled ? "square.dashed.inset.filled" : "square.fill")
                    .font(.callout).foregroundStyle(.secondary)
                if state.enabled && !state.cone {
                    nonCone(state)
                } else {
                    folderList
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
            Text("Files outside the chosen folders disappear from disk but stay in history. Files at the repository root are always kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if state?.enabled == true {
                    Button("Disable sparse checkout") { run { await repo.disableSparse() } }
                        .help("git sparse-checkout disable — every file comes back")
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if state?.enabled != true || state?.cone == true {
                    Button("Apply") { run { await repo.setSparse(selected.sorted()) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(state == nil)
                        .help("git sparse-checkout set --cone \(selected.sorted().joined(separator: " "))")
                }
            }
            .disabled(isRunning)
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task {
            if state == nil { await reload() }
            if tree[""] == nil { tree[""] = await repo.topLevelDirectories() }
        }
    }

    private var folderList: some View {
        List {
            if let roots = tree[""] {
                if roots.isEmpty { Text("No folders at HEAD.").foregroundStyle(.secondary) }
                ForEach(roots, id: \.self) { FolderRow(repo: repo, path: $0, tree: $tree, expanded: $expanded, selected: $selected) }
            } else {
                ProgressView()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func nonCone(_ state: SparseState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This checkout uses non-cone patterns, which this sheet can't edit:").font(.callout)
            ScrollView {
                Text(state.patterns.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Button("Convert to cone mode") {
                guard let dirs = SparseState.coneDirectories(fromPatterns: state.patterns) else {
                    errorText = "These patterns use globs or negations — cone mode can only list whole folders. Change them in a terminal, or disable sparse checkout."
                    return
                }
                run { await repo.setSparse(dirs) }
            }
        }
    }

    private func run(_ op: @escaping () async -> GitError?) {
        errorText = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            if let e = await op() {
                errorText = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                toasts.post(.success(repo.repo.name, detail: "Sparse checkout updated"))
            }
            await reload()
        }
    }

    private func reload() async {
        let s = await repo.sparseState()
        state = s
        selected = Self.initialSelection(s)
    }

    /// Cone semantics: checking a folder drops its now-redundant checked descendants.
    static func toggling(_ path: String, in selected: Set<String>) -> Set<String> {
        switch checkState(path, selected: selected) {
        case .on: return selected.subtracting([path])
        case .inherited: return selected
        case .partial, .off: return selected.filter { !$0.hasPrefix(path + "/") }.union([path])
        }
    }
}

/// One folder: checkbox + name, expanding into its subfolders (loaded on first expand).
private struct FolderRow: View {
    let repo: RepositoryStore
    let path: String
    @Binding var tree: [String: [String]]
    @Binding var expanded: Set<String>
    @Binding var selected: Set<String>

    private var isExpanded: Binding<Bool> {
        Binding(get: { expanded.contains(path) }, set: { open in
            if open { expanded.insert(path) } else { expanded.remove(path) }
            if open, tree[path] == nil {
                Task { tree[path] = await repo.topLevelDirectories(at: "HEAD:\(path)") }
            }
        })
    }

    var body: some View {
        if let kids = tree[path], kids.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                if let kids = tree[path] {
                    ForEach(kids, id: \.self) {
                        FolderRow(repo: repo, path: "\(path)/\($0)", tree: $tree, expanded: $expanded, selected: $selected)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: { label }
        }
    }

    private var label: some View {
        let state = SparseCheckoutSheet.checkState(path, selected: selected)
        return Button { selected = SparseCheckoutSheet.toggling(path, in: selected) } label: {
            HStack(spacing: 6) {
                Image(systemName: state.icon)
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.brand))
                .opacity(state == .inherited ? 0.5 : 1)
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(path.split(separator: "/").last.map(String.init) ?? path)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .inherited)
        .help(state.help)
    }
}
