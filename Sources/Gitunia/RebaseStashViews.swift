import SwiftUI
import GituniaCore

// MARK: - Rebase current branch onto another

/// A resolved rebase awaiting confirmation. Hosted in `ContentView` (via `RebaseOntoDialog`) and
/// set from `RepoToolbarContent`'s branch submenus, same "state lives in the host" shape as
/// `PendingBranchVerb` — a `ToolbarContent` can't host a dialog.
struct PendingRebase: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    let plan: RebasePlan
}

@MainActor
enum RebaseOntoRunner {
    /// Hard blockers toast and stop; "already contains it" toasts info and stops; otherwise the
    /// plan (commit counts, pushed-or-not, dirty count) is resolved and handed to the dialog.
    static func request(onto: String, on store: RepositoryStore, toasts: ToastCenter, pending: Binding<PendingRebase?>) {
        if let blocker = RebasePlan.blocker(repo: store.repo, operation: store.operation) {
            toasts.post(.error(store.repo.name, detail: blocker))
            return
        }
        Task {
            let plan = await store.rebasePlan(onto: onto)
            if plan.isUpToDate {
                toasts.post(.info(store.repo.name, detail: "\(plan.branch) already contains everything on \(onto) — nothing to rebase"))
                return
            }
            pending.wrappedValue = PendingRebase(store: store, plan: plan)
        }
    }

    /// Conflicts leave `operation == .rebase` for `ChangesView`'s operation banner; a plain failure
    /// is toasted by `ContentView`'s generic `lastError` watcher. Only success and the two
    /// "stopped" cases need words of their own here.
    static func perform(_ pending: PendingRebase, toasts: ToastCenter) async {
        let store = pending.store
        let plan = pending.plan
        switch await store.rebase(onto: plan.onto, autostash: plan.dirtyCount > 0) {
        case .rebased(let autostashConflicted):
            if autostashConflicted {
                toasts.post(.error(store.repo.name, detail: "Rebased onto \(plan.onto), but putting your uncommitted changes back conflicted. Resolve them with Keep Current / Keep Stashed in Changes; your changes are also kept as the stash entry \"autostash\"."))
            } else {
                var detail = "Rebased \(plan.branch) onto \(plan.onto)"
                if plan.pushedCount > 0 { detail += " — force push to update the remote" }
                toasts.post(.success(store.repo.name, detail: detail))
            }
        case .stoppedOnConflicts:
            toasts.post(.info(store.repo.name, detail: "Rebase stopped on conflicts — resolve them, then Continue (or Abort) in Changes"))
        case .failed:
            break
        }
    }
}

struct RebaseOntoDialog: ViewModifier {
    @Binding var pending: PendingRebase?
    @Environment(ToastCenter.self) private var toasts

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending?.plan.confirmTitle ?? "Rebase?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let current = pending {
                Button(current.plan.dirtyCount > 0 ? "Stash Changes and Rebase" : "Rebase") {
                    pending = nil
                    Task { await RebaseOntoRunner.perform(current, toasts: toasts) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.plan.confirmMessage ?? "")
        }
    }
}

// MARK: - Stash

@MainActor
enum StashRunner {
    static func title(_ item: StashItem) -> String {
        item.entry.message.isEmpty ? item.ref : item.entry.message
    }

    /// Apply/Pop never claims success unless git fully applied: conflicts get their own error
    /// toast (git writes no operation file for them, so there's no banner to fall back on), and a
    /// plain failure is left to `ContentView`'s generic `lastError` watcher.
    static func apply(_ item: StashItem, pop: Bool, on store: RepositoryStore, toasts: ToastCenter?) async {
        switch await store.stashApply(item, pop: pop) {
        case .applied:
            toasts?.post(.success(store.repo.name, detail: "\(pop ? "Popped" : "Applied") \"\(title(item))\"\(pop ? "" : " — the stash entry is kept")"))
        case .conflicts(let n):
            toasts?.post(.error(store.repo.name, detail: "\(pop ? "Pop" : "Apply") stopped with conflicts in \(n) file\(n == 1 ? "" : "s"). Resolve each with Keep Current / Keep Stashed in Changes (or edit it); the stash entry was kept."))
        case .failed:
            break
        }
    }

    static func drop(_ item: StashItem, on store: RepositoryStore, toasts: ToastCenter?) async {
        if await store.stashDrop(item) {
            toasts?.post(.success(store.repo.name, detail: "Dropped \"\(title(item))\""))
        }
    }

    static func stashSelected(_ changes: [FileChange], on store: RepositoryStore, toasts: ToastCenter?) async {
        let paths = Array(Set(changes.filter { $0.status != .conflicted }.map(\.path))).sorted()
        guard !paths.isEmpty else { return }
        switch await store.stashFiles(paths) {
        case .stashed:
            toasts?.post(.success(store.repo.name, detail: "Stashed \(paths.count) file\(paths.count == 1 ? "" : "s")"))
        case .nothingToStash:
            toasts?.post(.info(store.repo.name, detail: "Nothing to stash in the selected files"))
        case .otherFilesStaged(let others):
            let n = others.count
            toasts?.post(.error(store.repo.name, detail: "\(n) other staged file\(n == 1 ? " is" : "s are") outside your selection — git would put \(n == 1 ? "it" : "them") into this stash too. Unstage \(n == 1 ? "it" : "them") first, or select \(n == 1 ? "it" : "them") as well."))
        case .failed:
            break
        }
    }
}

/// Confirmation for dropping a chosen stash entry, used by both the action-row menu and the
/// Stashes sheet so the wording (what is lost) lives once.
struct StashDropConfirmation: ViewModifier {
    @Binding var item: StashItem?
    var store: RepositoryStore
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Drop \"\(item.map(StashRunner.title) ?? "stash")\"?",
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            titleVisibility: .visible
        ) {
            if let target = item {
                Button("Drop", role: .destructive) {
                    item = nil
                    Task { await StashRunner.drop(target, on: store, toasts: toasts) }
                }
            }
            Button("Cancel", role: .cancel) { item = nil }
        } message: {
            Text("The changes saved in this entry (\(item?.ref ?? "")) are deleted. Git can only get them back by hash, and only until it garbage-collects.")
        }
    }
}

/// The action row's stash menu: stash (plain or with a message), pop latest, and every entry with
/// Apply / Pop / Show / Drop. Owns its own prompt, sheet and drop confirmation so `ContentActionRow`
/// only has to place it. `ToastCenter` is read optionally so the row still renders in hosts that
/// don't inject one (`ActionRowRenderTests`).
struct StashMenu: View {
    var repo: RepositoryStore
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var items: [StashItem] = []
    @State private var messageTarget: RepositoryStore?
    @State private var sheetSelection: StashItem.ID?
    @State private var showSheet = false
    @State private var pendingDrop: StashItem?

    var body: some View {
        Menu {
            Button("Stash Changes") { Task { _ = await repo.stash() } }
                .disabled(!repo.repo.hasChanges || repo.isBusy)
            Button("Stash with Message…") { messageTarget = repo }
                .disabled(!repo.repo.hasChanges || repo.isBusy)
            Button("Pop Latest Stash") {
                if let latest = items.first { Task { await StashRunner.apply(latest, pop: true, on: repo, toasts: toasts) } }
            }
            .disabled(items.isEmpty || repo.isBusy)
            Button("Show Stashes…") { sheetSelection = items.first?.id; showSheet = true }
                .disabled(items.isEmpty)
            if !items.isEmpty {
                Divider()
                ForEach(items) { item in
                    Menu {
                        Button("Apply") { Task { await StashRunner.apply(item, pop: false, on: repo, toasts: toasts) } }
                        Button("Pop") { Task { await StashRunner.apply(item, pop: true, on: repo, toasts: toasts) } }
                        Button("Show…") { sheetSelection = item.id; showSheet = true }
                        Divider()
                        Button("Drop…", role: .destructive) { pendingDrop = item }
                    } label: {
                        // Gitunia's own auto-stashes: a tray glyph and the branch, not the raw label.
                        if let label = item.gituniaLabel {
                            Label("\(label.branch) — \(RelativeDate.string(for: label.date))", systemImage: "tray")
                        } else {
                            Text(item.entry.branch.isEmpty ? item.entry.message : "\(item.entry.branch): \(item.entry.message)")
                        }
                    }
                    .disabled(repo.isBusy)
                }
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
        }
        // Hides the chevron a default `Menu` label draws — with an icon-only label there's no
        // room to spare for it at the content column's minimum width.
        .menuIndicator(.hidden)
        .help(repo.stashCount > 0 ? "Stash (\(repo.stashCount))" : "Stash")
        .disabled(repo.isBusy)
        // Re-fetches whenever the count changes (after a push/pop/drop, or the lazy refresh
        // ContentView runs on repo selection) rather than polling.
        .task(id: repo.stashCount) { items = await repo.stashItems() }
        .modifier(StashMessagePrompt(target: $messageTarget))
        .sheet(isPresented: $showSheet) {
            StashesSheet(repo: repo, selection: $sheetSelection)
        }
        .modifier(StashDropConfirmation(item: $pendingDrop, store: repo))
    }
}

/// "Stash with message" prompt, shared by the stash menu and ⌘K. Stashes `target` on confirm.
struct StashMessagePrompt: ViewModifier {
    @Binding var target: RepositoryStore?
    var onFinish: () -> Void = {}
    @State private var message = ""

    func body(content: Content) -> some View {
        content.alert("Stash with message", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            TextField("Message", text: $message)
            Button("Stash") {
                let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                message = ""
                if let store = target { Task { _ = await store.stash(message: text.isEmpty ? nil : text) } }
                target = nil
                onFinish()
            }
            Button("Cancel", role: .cancel) { message = ""; target = nil; onFinish() }
        } message: {
            Text("Stashes all changes, including untracked files.")
        }
    }
}

/// Loads entries and the selected entry's diff for `StashesSheetContent`.
struct StashesSheet: View {
    var repo: RepositoryStore
    @Binding var selection: StashItem.ID?
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @Environment(\.dismiss) private var dismiss
    @State private var items: [StashItem] = []
    @State private var files: [FileDiff] = []
    @State private var selectedPath: String?
    @State private var pendingDrop: StashItem?

    var body: some View {
        StashesSheetContent(
            items: items, selection: $selection, files: files, selectedPath: $selectedPath,
            isBusy: repo.isBusy,
            onApply: { item in Task { await StashRunner.apply(item, pop: false, on: repo, toasts: toasts) } },
            onPop: { item in Task { await StashRunner.apply(item, pop: true, on: repo, toasts: toasts) } },
            onDrop: { pendingDrop = $0 },
            onDone: { dismiss() }
        )
        .task(id: repo.stashCount) {
            items = await repo.stashItems()
            if selection == nil || !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
        }
        .task(id: selection) {
            guard let item = items.first(where: { $0.id == selection }) else { files = []; return }
            files = await repo.stashDiff(item)
            selectedPath = files.first?.path
        }
        .modifier(StashDropConfirmation(item: $pendingDrop, store: repo))
    }
}

/// Plain-value content so the offscreen render test can instantiate it directly — a `.sheet`
/// never composites offscreen, only its content does (same split as `CleanPreviewSheetContent`).
struct StashesSheetContent: View {
    let items: [StashItem]
    @Binding var selection: StashItem.ID?
    let files: [FileDiff]
    @Binding var selectedPath: String?
    var isBusy = false
    var onApply: (StashItem) -> Void = { _ in }
    var onPop: (StashItem) -> Void = { _ in }
    var onDrop: (StashItem) -> Void = { _ in }
    var onDone: () -> Void = {}
    @AppStorage("diffMode") private var mode: DiffMode = .inline
    @AppStorage("diffWrap") private var wrap = false

    private var selected: StashItem? { items.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                entryList.frame(width: 240)
                Divider()
                if files.count > 1 {
                    fileList.frame(width: 180)
                    Divider()
                }
                diffPane
            }
            Divider()
            HStack {
                if let selected {
                    Text(selected.ref).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Drop…", role: .destructive) { selected.map(onDrop) }
                    .foregroundStyle(.red)
                Button("Pop") { selected.map(onPop) }
                Button("Apply") { selected.map(onApply) }
                    .help("Apply the changes and keep the stash entry")
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .disabled(isBusy && selected != nil)
            .padding(12)
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    private var entryList: some View {
        List(items, selection: $selection) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(StashRunner.title(item)).lineLimit(1)
                Text([item.entry.branch, RelativeDate.string(for: item.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .overlay { if items.isEmpty { ContentUnavailableView("No stashes", systemImage: "tray") } }
    }

    private var fileList: some View {
        List(files, id: \.path, selection: $selectedPath) { file in
            Text(file.path).lineLimit(1).truncationMode(.head)
        }
    }

    private var diffPane: some View {
        Group {
            if let file = files.first(where: { $0.path == selectedPath }) ?? (files.count == 1 ? files.first : nil) {
                if file.isBinary {
                    ContentUnavailableView("Binary file", systemImage: "doc.zipper")
                } else {
                    DiffBodyView(diff: file, mode: mode, fileExtension: (file.path as NSString).pathExtension, wrap: wrap)
                }
            } else {
                ContentUnavailableView("Select a stash", systemImage: "tray")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
