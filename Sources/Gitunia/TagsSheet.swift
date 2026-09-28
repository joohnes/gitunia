import SwiftUI
import GituniaCore

// MARK: - Tag badges (History rows)

/// Small brand capsules naming the tags on a commit.
struct TagBadges: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(names, id: \.self) { name in
                Label(name, systemImage: "tag.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.brand.opacity(0.14), in: Capsule())
                    .lineLimit(1)
            }
        }
        .help("Tags: \(names.joined(separator: ", "))")
    }
}

// MARK: - Tags sheet

/// Pure-values content of the Tags sheet, split out (like `CleanPreviewSheetContent`) so the
/// offscreen render can instantiate it directly.
struct TagsSheetContent: View {
    let tags: [GitTag]
    let remote: String?
    var onCheckout: (GitTag) -> Void
    var onPush: (GitTag) -> Void
    var onDelete: (GitTag) -> Void
    var onDeleteRemote: (GitTag) -> Void
    var onPushAll: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                Button("Push All Tags…", systemImage: "arrow.up.circle", action: onPushAll)
                    .disabled(tags.isEmpty || remote == nil)
                    .help(remote.map { "git push \($0) --tags" } ?? "No remote configured")
            }
            if tags.isEmpty {
                Text("No tags yet. Right-click a commit in History → Create Tag….")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(tags) { tag in
                    HStack(spacing: 8) {
                        Image(systemName: "tag").foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(tag.name).fontWeight(.medium)
                                Text(String(tag.commitHash.prefix(7))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if tag.isAnnotated {
                                    Text("annotated").font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                                }
                            }
                            if let message = tag.message {
                                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Check Out (detached)") { onCheckout(tag) }
                            Button("Push Tag") { onPush(tag) }.disabled(remote == nil)
                            Divider()
                            Button("Delete…", role: .destructive) { onDelete(tag) }
                            Button("Delete on Remote…", role: .destructive) { onDeleteRemote(tag) }.disabled(remote == nil)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More actions")
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Owns tag state and the destructive confirmations; git calls go through `RepositoryStore+Tags`.
struct TagsSheet: View {
    var repo: RepositoryStore
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var remote: String?
    @State private var pending: Pending?

    enum Pending: Identifiable {
        case delete(GitTag), deleteRemote(GitTag), pushAll
        var id: String {
            switch self {
            case .delete(let t): "d-\(t.name)"
            case .deleteRemote(let t): "r-\(t.name)"
            case .pushAll: "all"
            }
        }
    }

    var body: some View {
        TagsSheetContent(
            tags: repo.gitTags, remote: remote,
            onCheckout: checkout,
            onPush: { tag in Task { if await repo.pushTag(tag.name) { toasts.post(.success("Pushed tag \(tag.name)", detail: remote)) } } },
            onDelete: { pending = .delete($0) },
            onDeleteRemote: { pending = .deleteRemote($0) },
            onPushAll: { pending = .pushAll },
            onDone: { dismiss() }
        )
        .task {
            await repo.refreshTags()
            remote = await repo.tagRemote()
        }
        .confirmationDialog(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(confirmButton, role: isPushAll ? nil : .destructive, action: confirm)
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(message)
        }
    }

    private var remoteName: String { remote ?? "the remote" }
    private var isPushAll: Bool { if case .pushAll = pending { true } else { false } }

    private var title: String {
        switch pending {
        case .delete(let t): "Delete tag \"\(t.name)\"?"
        case .deleteRemote(let t): "Delete tag \"\(t.name)\" on \(remoteName)?"
        case .pushAll: Self.pushAllTitle(count: repo.gitTags.count, remote: remote)
        case nil: ""
        }
    }

    /// Push-all wording, shared with ⌘K's "Push All Tags…".
    static func pushAllTitle(count: Int, remote: String?) -> String { "Push all \(count) tags to \(remote ?? "the remote")?" }
    static func pushAllMessage(tags: [GitTag], remote: String?) -> String {
        "git push \(remote ?? "the remote") --tags:\n" + tags.map(\.name).joined(separator: ", ")
    }

    private var confirmButton: String {
        switch pending {
        case .delete: "Delete Tag"
        case .deleteRemote: "Delete on Remote"
        case .pushAll, nil: "Push All Tags"
        }
    }

    private var message: String {
        switch pending {
        case .delete(let t):
            "Removes the local tag \(t.name) (on \(t.commitHash.prefix(7)))\(t.isAnnotated ? " and its annotation message" : ""). The commit stays; a copy already pushed to \(remoteName) is not affected."
        case .deleteRemote(let t):
            "Removes \(t.name) from \(remoteName) — it affects everyone using that remote. Your local tag stays."
        case .pushAll:
            Self.pushAllMessage(tags: repo.gitTags, remote: remote)
        case nil: ""
        }
    }

    private func confirm() {
        guard let action = pending else { return }
        pending = nil
        Task {
            switch action {
            case .delete(let t):
                if await repo.deleteTag(t.name) { toasts.post(.success("Deleted tag \(t.name)", detail: repo.repo.name)) }
            case .deleteRemote(let t):
                if await repo.deleteRemoteTag(t.name) { toasts.post(.success("Deleted tag \(t.name) on \(remoteName)", detail: repo.repo.name)) }
            case .pushAll:
                if await repo.pushAllTags() { toasts.post(.success("Pushed all tags to \(remoteName)", detail: repo.repo.name)) }
            }
        }
    }

    /// Same checkout preflight as the branch menu, but blockers just toast — no override here.
    private func checkout(_ tag: GitTag) {
        let issues = Preflight.check(.checkout(branch: tag.name), repo: repo.repo, hasUpstream: repo.hasUpstream, operationInProgress: repo.operation != nil)
        if let blocker = issues.first(where: { $0.severity == .blocker }) {
            toasts.post(.error(repo.repo.name, detail: blocker.message))
            return
        }
        Task {
            if await repo.checkoutTag(tag.name) {
                toasts.post(.success("Checked out \(tag.name)", detail: "Detached HEAD — create a branch to keep new commits"))
                dismiss()
            }
        }
    }
}

// MARK: - History commit menu: Create Tag / Create Branch Here

/// What a History commit's context menu asked to create at that commit.
enum PendingCommitRef: Identifiable {
    case tag(CommitInfo), branch(CommitInfo)
    var id: String {
        switch self {
        case .tag(let c): "t-\(c.hash)"
        case .branch(let c): "b-\(c.hash)"
        }
    }
}

/// The two History context-menu items, one contiguous block for `HistoryView`'s `.contextMenu`.
struct CommitRefMenuItems: View {
    let commit: CommitInfo
    @Binding var pending: PendingCommitRef?

    var body: some View {
        Divider()
        Button("Create Tag…", systemImage: "tag") { pending = .tag(commit) }
        Button("Create Branch Here…", systemImage: "arrow.triangle.branch") { pending = .branch(commit) }
        Divider()
    }
}

/// Hosts the create-tag sheet and the create-branch alert (the New Branch alert's shape, plus a
/// "Create and Check Out" button since macOS alerts can't hold a toggle).
struct CommitRefDialogs: ViewModifier {
    var repo: RepositoryStore
    @Binding var pending: PendingCommitRef?
    @Environment(ToastCenter.self) private var toasts
    @State private var branchName = ""

    private var tagCommit: Binding<CommitInfo?> {
        Binding(get: { if case .tag(let c) = pending { c } else { nil } }, set: { if $0 == nil { pending = nil } })
    }

    private var branchCommit: CommitInfo? { if case .branch(let c) = pending { c } else { nil } }

    func body(content: Content) -> some View {
        content
            .sheet(item: tagCommit) { commit in CreateTagSheet(repo: repo, commit: commit) }
            .alert("New branch", isPresented: Binding(get: { branchCommit != nil }, set: { if !$0 { pending = nil; branchName = "" } })) {
                TextField("Branch name", text: $branchName)
                Button("Create") { create(checkout: false) }
                Button("Create and Check Out") { create(checkout: true) }
                Button("Cancel", role: .cancel) { pending = nil; branchName = "" }
            } message: {
                Text("Creates the branch at \(branchCommit?.shortHash ?? "") \"\(branchCommit?.subject ?? "")\".")
            }
    }

    private func create(checkout: Bool) {
        guard let commit = branchCommit else { return }
        let name = branchName
        pending = nil
        branchName = ""
        Task {
            switch await repo.createBranch(name, at: commit.hash, checkout: checkout) {
            case .succeeded:
                toasts.post(.success(checkout ? "Switched to new branch \(name)" : "Created branch \(name)", detail: "at \(commit.shortHash)"))
            case .invalidName(let reason): toasts.post(.error(repo.repo.name, detail: reason))
            case .duplicateName: toasts.post(.error(repo.repo.name, detail: "A branch named \"\(name)\" already exists"))
            case .failed: break // ContentView's generic lastError watcher already toasts git's message.
            }
        }
    }
}

/// Pure-values content of the create-tag sheet (rendered directly by the render tests).
struct CreateTagSheetContent: View {
    let commit: CommitInfo
    @Binding var name: String
    @Binding var message: String
    let error: String?
    var onCancel: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create Tag").font(.headline)
            Text("At \(commit.shortHash) — \(commit.subject)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            TextField("Tag name (e.g. v1.2.0)", text: $name)
            TextField("Message (optional)", text: $message, axis: .vertical)
                .lineLimit(3...6)
            Text(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "No message → lightweight tag (just a name on the commit)."
                 : "With a message → annotated tag (records tagger, date and message).")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create Tag", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Validation errors (invalid/duplicate name) stay inline so the user can fix the name in place.
struct CreateTagSheet: View {
    var repo: RepositoryStore
    let commit: CommitInfo
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message = ""
    @State private var error: String?

    var body: some View {
        CreateTagSheetContent(commit: commit, name: $name, message: $message, error: error, onCancel: { dismiss() }, onCreate: create)
    }

    private func create() {
        Task {
            switch await repo.createTag(name, at: commit.hash, message: message) {
            case .succeeded:
                toasts.post(.success("Tagged \(commit.shortHash) as \(name.trimmingCharacters(in: .whitespacesAndNewlines))", detail: repo.repo.name))
                dismiss()
            case .invalidName(let reason): error = reason
            case .duplicateName: error = "A tag named \"\(name.trimmingCharacters(in: .whitespacesAndNewlines))\" already exists"
            case .failed: dismiss() // generic lastError watcher toasts git's message
            }
        }
    }
}
