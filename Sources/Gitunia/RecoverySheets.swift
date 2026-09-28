import SwiftUI
import GituniaCore

/// Every place HEAD has been, newest first — the safety net after a reset, amend or rebase (by an
/// agent or by hand) seemed to lose commits.
struct ReflogSheet: View {
    var store: RepositoryStore
    var onDone: () -> Void
    @Environment(RecoveryCoordinator.self) private var recovery: RecoveryCoordinator?
    @Environment(ToastCenter.self) private var toasts
    @State private var entries: [ReflogEntry] = []
    @State private var stashes: [StashItem] = []
    @State private var fileCounts: [String: Int] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reflog — \(store.repo.name)").font(.headline)
                Text("Every commit HEAD has pointed at, newest first. Commits undone by a reset, amend or rebase are still here — right-click one to get it back.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            List {
                if stashes.isEmpty {
                    reflogRows
                } else {
                    Section("Stashed by Gitunia") {
                        ForEach(stashes) { item in
                            GituniaStashRow(item: item, fileCount: fileCounts[item.hash], currentBranch: store.repo.branch,
                                            busy: store.isBusy || recovery == nil) { pop in
                                recovery?.requestStashRestore(store, item: item, pop: pop, toasts: toasts)
                            }
                        }
                    }
                    Section("Reflog") { reflogRows }
                }
            }
            .overlay {
                if loaded && entries.isEmpty && stashes.isEmpty { ContentUnavailableView("No reflog yet", systemImage: "clock.arrow.circlepath") }
            }
            Divider()
            HStack {
                Text("On \(store.repo.branchLabel)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 440)
        .task(id: "\(store.repo.headOID ?? "")-\(store.repo.branch ?? "")-\(store.stashCount)") {
            // Both assigned together: inserting the stash section above an already-shown reflog
            // makes the List keep its scroll anchor and open scrolled past the first stash.
            let reflog = await store.reflog()
            stashes = await store.gituniaStashes()
            entries = reflog
            // ponytail: one `stash show` per row, so only the newest 20 get a count.
            for item in stashes.prefix(20) where fileCounts[item.hash] == nil {
                fileCounts[item.hash] = await store.stashFileCount(item)
            }
            loaded = true
        }
    }

    private var reflogRows: some View {
        ForEach(entries) { entry in
            ReflogRow(entry: entry)
                .contextMenu { menu(for: entry) }
        }
    }

    @ViewBuilder
    private func menu(for entry: ReflogEntry) -> some View {
        Button("Copy SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.hash, forType: .string)
        }
        if let recovery {
            Divider()
            Button("Create Branch Here…") { recovery.requestCreateBranch(store, at: entry.hash, shortHash: entry.shortHash) }
            Button("Check Out This Commit…") {
                recovery.requestCheckoutCommit(store, hash: entry.hash, shortHash: entry.shortHash, subject: entry.message)
            }
            if !store.repo.isDetached {
                Button("Reset \(store.repo.branch ?? "Current Branch") Here…") {
                    Task { await recovery.requestReset(store, to: entry.hash, shortHash: entry.shortHash, subject: entry.message, toasts: toasts) }
                }
            }
        }
    }
}

struct ReflogRow: View {
    let entry: ReflogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.selector).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(entry.kind)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.isRewrite(entry.kind) ? Theme.brand : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background((Self.isRewrite(entry.kind) ? Theme.brand : Color.secondary).opacity(0.14), in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message.isEmpty ? entry.action : entry.message).lineLimit(1)
                if entry.action != entry.kind {
                    Text(entry.action).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(entry.shortHash).font(.caption.monospaced())
            Text(RelativeDate.string(for: entry.date))
                .font(.caption).foregroundStyle(.secondary)
                .help(RelativeDate.absolute(entry.date))
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// The actions that move a branch backwards or rewrite it — the rows worth noticing.
    static func isRewrite(_ kind: String) -> Bool { ["reset", "amend", "rebase"].contains(kind) }
}

/// A stash Gitunia made on a branch switch (`StashLabel`): its branch, age, size, and the two ways
/// back. `onRestore(pop)` — the coordinator asks first when the stash's branch isn't the current one.
struct GituniaStashRow: View {
    let item: StashItem
    let fileCount: Int?
    let currentBranch: String?
    let busy: Bool
    let onRestore: (Bool) -> Void

    var body: some View {
        let branch = item.gituniaLabel?.branch ?? item.entry.branch
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray").foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch).lineLimit(1)
                Text([fileCount.map { "\($0) file\($0 == 1 ? "" : "s")" },
                      branch == currentBranch ? nil : "made on another branch"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(RelativeDate.string(for: item.date))
                .font(.caption).foregroundStyle(.secondary)
                .help(RelativeDate.absolute(item.date))
            Button("Apply (keep)") { onRestore(false) }
                .help("Put the changes back and keep the stash")
            Button("Restore (pop)") { onRestore(true) }
                .help("Put the changes back and drop the stash")
        }
        .controlSize(.small)
        .disabled(busy)
        .padding(.vertical, 2)
    }
}

/// Reset <branch> to a commit: the three modes in plain words, what's undone, and — for Hard —
/// exactly which uncommitted files are discarded.
struct ResetSheet: View {
    let plan: ResetPlan
    var onCancel: () -> Void
    var onReset: (ResetMode) -> Void
    @State private var mode: ResetMode

    init(plan: ResetPlan, initialMode: ResetMode = .mixed, onCancel: @escaping () -> Void, onReset: @escaping (ResetMode) -> Void) {
        self.plan = plan
        self.onCancel = onCancel
        self.onReset = onReset
        self._mode = State(initialValue: initialMode)
    }

    private var undoneText: String {
        switch plan.impact.undone {
        case 0: return "No commits are undone — \(plan.branch) already contains this commit at its tip."
        case 1: return "1 commit on \(plan.branch) will be undone."
        default: return "\(plan.impact.undone) commits on \(plan.branch) will be undone."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset \(plan.branch) to \(plan.targetShortHash)").font(.headline)
            Text("\"\(plan.targetSubject)\"").font(.callout).lineLimit(2)
            Text(undoneText).font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ResetMode.allCases, id: \.self) { m in
                    Button { mode = m } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(mode == m ? Theme.brand : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title).fontWeight(.semibold)
                                Text(m.explanation).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(plan.warnings.filter { $0.severity == .warning }) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mode == .hard {
                VStack(alignment: .leading, spacing: 4) {
                    if plan.lostFiles.isEmpty {
                        Text("No uncommitted changes will be lost.").font(.callout)
                    } else {
                        Text("These uncommitted changes will be discarded for good:")
                            .font(.callout.weight(.semibold)).foregroundStyle(Theme.status(.deleted))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(plan.lostFiles, id: \.self) { Text($0).font(.system(.callout, design: .monospaced)).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: min(CGFloat(plan.lostFiles.count) * 19, 120))
                        Text("Untracked files are left alone.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Theme.status(.deleted).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if plan.impact.undone > 0 {
                Text("Undone commits stay recoverable from the Reflog for a while.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                // Return never discards files: Hard needs a click, and reads as destructive (red,
                // like every other irreversible button in the app).
                if mode == .hard {
                    Button(resetTitle, role: .destructive) { onReset(mode) }
                        .foregroundStyle(.red)
                } else {
                    Button(resetTitle) { onReset(mode) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var resetTitle: String {
        guard mode == .hard, !plan.lostFiles.isEmpty else { return "Reset (\(mode.title))" }
        let n = plan.lostFiles.count
        return "Discard \(n) File\(n == 1 ? "" : "s") and Reset"
    }
}
