import SwiftUI
import GituniaCore

/// Per-repository editor for the few config keys in `GitConfigCatalog` whose per-repo differences
/// cause surprises. Pickers/fields write the repository's local config; "Set Globally" lives in
/// each row's context menu. Worktree-scoped values are shown read-only.
struct GitConfigSheet: View {
    let repo: RepositoryStore
    var editorBundleID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorOpenCoordinator.self) private var editorRequests: EditorOpenCoordinator?
    @State private var values: [String: ConfigValue] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var error: String?
    private let injected: Bool

    init(repo: RepositoryStore, editorBundleID: String? = nil, initialValues: [ConfigValue]? = nil) {
        self.repo = repo
        self.editorBundleID = editorBundleID
        self.injected = initialValues != nil
        let map = Dictionary((initialValues ?? []).map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        _values = State(initialValue: map)
        _drafts = State(initialValue: map.compactMapValues { $0.scope == .local ? $0.value : nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Git Config — \(repo.repo.name)").font(.title3.bold()).padding([.horizontal, .top], 20)
            Form {
                ForEach(GitConfigCatalog.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(GitConfigCatalog.keys.filter { $0.group == group }) { row($0) }
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
            }
            HStack {
                Button("Edit .git/config…", systemImage: "square.and.pencil") { editConfigFile() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560)
        .frame(minHeight: 480, idealHeight: 640)
        .task { if !injected { await reload() } }
    }

    private func row(_ item: GitConfigCatalog.ConfigKey) -> some View {
        let value = values[item.key] ?? ConfigValue(key: item.key, value: nil, scope: .unset)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                control(item, value)
                ScopeBadge(scope: value.scope)
                Button("Edit in…", systemImage: "square.and.pencil") { editConfigFile() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Open .git/config in your editor")
            }
            Text(.init(item.explanation)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contextMenu { globalMenu(item, value) }
    }

    @ViewBuilder
    private func control(_ item: GitConfigCatalog.ConfigKey, _ value: ConfigValue) -> some View {
        let label = Text(item.title).help(item.key)
        if value.scope == .worktree {
            LabeledContent { Text(value.value ?? "").foregroundStyle(.secondary) } label: { label }
                .help("Set in this worktree's config.worktree — edit it there")
        } else if case .text = item.kind {
            TextField(text: Binding(get: { drafts[item.key] ?? "" }, set: { drafts[item.key] = $0 }),
                      prompt: Text(value.inherited ?? "not set")) { label }
                .onSubmit { write(item.key, drafts[item.key].flatMap { $0.isEmpty ? nil : $0 }, scope: .local) }
        } else {
            Picker(selection: Binding(get: { value.scope == .local ? value.value : nil },
                                      set: { write(item.key, $0, scope: .local) })) {
                Text("Inherited (\(value.inherited ?? "unset"))").tag(String?.none)
                ForEach(options(item, value), id: \.self) { Text($0).tag(String?.some($0)) }
            } label: { label }
        }
    }

    /// The kind's values, plus a local value git accepts but the list doesn't spell (`yes`, `on`…).
    private func options(_ item: GitConfigCatalog.ConfigKey, _ value: ConfigValue?) -> [String] {
        var list: [String]
        switch item.kind {
        case .bool: list = ["true", "false"]
        case .choice(let c): list = c
        case .text: list = []
        }
        if let v = value?.value, value?.scope == .local, !list.contains(v) { list.append(v) }
        return list
    }

    @ViewBuilder
    private func globalMenu(_ item: GitConfigCatalog.ConfigKey, _ value: ConfigValue) -> some View {
        if case .text = item.kind {
            if value.scope == .local, let v = value.value {
                Button("Set Globally to \"\(v)\"") { write(item.key, v, scope: .global) }
            }
        } else {
            Menu("Set Globally") {
                ForEach(options(item, nil), id: \.self) { v in Button(v) { write(item.key, v, scope: .global) } }
            }
        }
        if value.scope == .local {
            Button("Remove Local Setting") { write(item.key, nil, scope: .local) }
        }
    }

    private func write(_ key: String, _ value: String?, scope: ConfigValue.Scope) {
        Task {
            if let failure = await repo.setConfig(key, value: value, scope: scope) {
                error = failure.localizedDescription
            } else {
                error = nil
            }
            await reload()
        }
    }

    private func reload() async {
        let list = await repo.configValues(for: GitConfigCatalog.keys.map(\.key))
        values = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        drafts = values.compactMapValues { $0.scope == .local ? $0.value : nil }
    }

    /// A linked worktree's `.git` is a file; the shared config lives in the main checkout's `.git`.
    private func editConfigFile() {
        guard let dir = repo.worktreeParent.map({ $0.appendingPathComponent(".git") }) ?? repo.gitDirURL() else { return }
        let file = dir.appendingPathComponent("config")
        dismiss() // the editor chooser (if needed) is a ContentView sheet — can't stack on this one
        editorRequests?.open(file, configuredBundleID: editorBundleID)
    }
}

private struct ScopeBadge: View {
    let scope: ConfigValue.Scope

    var body: some View {
        let tint: Color = switch scope {
        case .local, .worktree: Theme.brand
        case .global, .system: .secondary
        case .unset: Color.secondary.opacity(0.6)
        }
        Text(scope.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .frame(width: 64)
    }
}
