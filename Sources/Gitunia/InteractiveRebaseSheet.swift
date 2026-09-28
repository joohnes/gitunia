import SwiftUI
import GituniaCore

/// Pure-values content of "Tidy Commits…" (rendered directly by the render tests). `rows` is in
/// History order — newest at the top; the todo runs them reversed.
struct InteractiveRebaseSheetContent: View {
    /// Why it can't run at all (dirty tree, operation in progress, nothing unpushed…), shown in
    /// place of the list.
    let blocker: String?
    let isLoading: Bool
    @Binding var rows: [RebaseTodo.Line]
    let error: String?
    var onCancel: () -> Void
    var onRebase: () -> Void

    private var todo: [RebaseTodo.Line] { rows.reversed() }
    private var problem: String? { RebaseTodo.validate(todo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tidy Commits").font(.headline)
            Text("Unpushed commits, newest first. Squash and fixup fold a commit into the one below it; drag to reorder.")
                .font(.callout).foregroundStyle(.secondary)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else if let blocker {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(Array(rows.enumerated()), id: \.element.hash) { index, _ in
                        rowView($rows[index], index: index)
                    }
                    .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 160, maxHeight: 380)
                Text(problem ?? RebaseTodo.summary(todo))
                    .font(.caption).foregroundStyle(problem == nil ? Color.secondary : Color.red)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Rebase…", action: onRebase)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || blocker != nil || problem != nil || rows.allSatisfy { $0.action == .pick })
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func rowView(_ row: Binding<RebaseTodo.Line>, index: Int) -> some View {
        let line = row.wrappedValue
        let editsMessage = line.action == .reword || line.action == .squash
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                reorderButtons(index: index)
                Picker("", selection: Binding(get: { line.action }, set: { setAction($0, for: line.hash) })) {
                    ForEach(RebaseTodo.Action.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                Text(line.hash.prefix(7)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(line.subject).lineLimit(1)
                    .strikethrough(line.action == .drop)
                    .foregroundStyle(line.action == .drop || line.action == .fixup ? .secondary : .primary)
            }
            if editsMessage {
                TextField("Message", text: Binding(get: { row.wrappedValue.newMessage ?? "" }, set: { row.wrappedValue.newMessage = $0 }),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 98)
            }
        }
        .padding(.vertical, 2)
    }

    /// ▲/▼ fallback for drag-to-reorder (B11 — `.onMove` is unverified live in a real `List`).
    /// Hidden (not just disabled) at the array's ends so there's nothing to tap into a no-op.
    @ViewBuilder
    private func reorderButtons(index: Int) -> some View {
        VStack(spacing: 0) {
            if index > 0 {
                Button { rows = RebaseTodo.moveLine(rows, from: index, to: index - 1) } label: {
                    Image(systemName: "chevron.up")
                }
            }
            if index < rows.count - 1 {
                Button { rows = RebaseTodo.moveLine(rows, from: index, to: index + 1) } label: {
                    Image(systemName: "chevron.down")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .frame(width: 16)
    }

    private func setAction(_ action: RebaseTodo.Action, for hash: String) {
        guard let i = rows.firstIndex(where: { $0.hash == hash }) else { return }
        rows[i].action = action
        if rows[i].newMessage == nil || rows[i].newMessage?.isEmpty == true {
            if action == .reword { rows[i].newMessage = rows[i].subject }
            if action == .squash { rows[i].newMessage = Self.combinedMessage(at: i, in: rows) }
        }
    }

    /// Subjects of the group row `i` squashes into (older rows below it, down to the first
    /// pick/reword), oldest first — what git itself would offer.
    static func combinedMessage(at i: Int, in rows: [RebaseTodo.Line]) -> String {
        var group = [rows[i].subject]
        for older in rows[(i + 1)...] where older.action != .drop {
            group.insert(older.subject, at: 0)
            if older.action == .pick || older.action == .reword { break }
        }
        return group.joined(separator: "\n\n")
    }
}

/// Loads the rewritable commits (optionally only those newer than or equal to `since`), confirms
/// naming the base, runs `interactiveRebase`, toasts.
struct InteractiveRebaseSheet: View {
    var repo: RepositoryStore
    var since: String? = nil
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [RebaseTodo.Line] = []
    @State private var blocker: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirming = false

    var body: some View {
        InteractiveRebaseSheetContent(
            blocker: blocker, isLoading: isLoading, rows: $rows, error: error,
            onCancel: { dismiss() }, onRebase: { confirming = true }
        )
        .task { await load() }
        .confirmationDialog("Rewrite \(rows.count) commit\(rows.count == 1 ? "" : "s")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Rebase") { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replays them on top of \(rows.last.map { "\($0.hash.prefix(7))^" } ?? "the base") (\(RebaseTodo.summary(rows.reversed()))). Every rewritten commit gets a new hash; none are pushed yet.")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let why = repo.interactiveRebaseBlocker { blocker = why; return }
        var commits = await repo.rewritableCommits()
        if let since {
            guard let i = commits.firstIndex(where: { $0.hash == since }) else {
                blocker = "That commit is already pushed (or no longer on this branch) — only unpushed commits can be tidied"
                return
            }
            commits = Array(commits[...i])
        }
        if commits.isEmpty { blocker = "No unpushed commits to tidy"; return }
        if commits.contains(where: { $0.parentCount > 1 }) { blocker = "There's a merge commit among these — tidying can't keep it"; return }
        rows = commits.map { RebaseTodo.Line(hash: $0.hash, subject: $0.subject) }
    }

    private func run() async {
        let before = rows.count
        if let e = await repo.interactiveRebase(rows.reversed()) {
            error = e.stderr.isEmpty ? e.localizedDescription : e.stderr
            return
        }
        if repo.operation == .rebase {
            toasts.post(.info(repo.repo.name, detail: "Rebase stopped on conflicts — resolve them, then Continue (or Abort) in Changes"))
        } else {
            toasts.post(.success(repo.repo.name, detail: "Tidied \(before) commit\(before == 1 ? "" : "s")"))
        }
        dismiss()
    }
}
