import SwiftUI
import GituniaCore

/// One page of history at a time, then a "Load More" row — `List` gives no reliable
/// "reached the bottom" signal, and a row is deterministic and easy to render-test.
private let historyPageSize = 200

struct HistoryView: View {
    var repo: RepositoryStore
    @Binding var selection: CommitInfo?
    @Environment(ToastCenter.self) private var toasts
    @Environment(RecoveryCoordinator.self) private var recovery: RecoveryCoordinator?
    @Environment(RepoSheets.self) private var repoSheets: RepoSheets?
    @State private var commits: [CommitInfo] = []
    /// `nil` means "the current branch" — the picker's default and what resets to on repo change.
    @State private var selectedBranch: String?
    /// Hashes on `selectedBranch` not reachable from HEAD — empty whenever `selectedBranch` is nil
    /// (viewing the current branch, where every listed commit is by definition an ancestor of HEAD).
    /// These are exactly the commits "Cherry-pick" applies to; every other listed commit is exactly
    /// what "Revert" applies to (it's reachable from HEAD).
    @State private var cherryPickable: Set<String> = []
    @State private var pendingUndo: PendingUndo?
    @State private var pendingRevert: CommitInfo?
    @State private var pendingCherryPick: CommitInfo?
    @State private var pendingRestore: PendingRestore?
    @State private var pendingCommitRef: PendingCommitRef?
    @State private var filterText = ""
    /// The "Unreviewed" chip: restricts the list to `reviewedHead..HEAD`.
    @State private var unreviewedOnly: Bool
    /// The "Agent commits" chip: hides loaded rows `repo.agentProfile` doesn't match (client-side).
    @State private var agentOnly: Bool
    @State private var hasMore = false
    @State private var isLoadingMore = false
    /// True while the main `.task(id:)` is fetching (not "Load More"), so a slow repo shows a
    /// spinner instead of a misleading "No commits" flash.
    @State private var isLoading = false
    /// The context (repo/branch/filter/file-history path) the last load was for, *without*
    /// `lastCommitSummary`: a new commit landing keeps paging, a real context change resets it.
    @State private var lastLoadContext: String?
    /// Only populated in file-history mode (`fileHistoryPath != nil`) — the source of `commits` and
    /// of the per-commit path/kind a restore action or `CommitDiffView`'s preselect needs.
    @State private var fileHistoryEntries: [FileHistoryEntry] = []
    @FocusState private var filterFocused: Bool

    /// Test-only seam: starts the branch picker on a non-current branch without simulating a click.
    var initialBranch: String?
    /// Test-only seam, same shape: starts the filter field pre-filled without simulating typing.
    var initialFilterText: String = ""
    /// Test-only seam, same shape: starts with the "Unreviewed" chip on.
    var initialUnreviewedOnly: Bool = false
    /// ⌘K's "Search History…" sets this to request the filter field take focus — `ContentView`
    /// flips it back to `false` once consumed (see `onChange` below). Defaults to a constant so
    /// every other call site (including render-test harnesses) can ignore it.
    var focusFilterRequested: Binding<Bool> = .constant(false)
    /// Non-nil switches this view into file-history mode for that repo-relative path: the branch
    /// picker and filter give way to a removable "File: <path>" chip, and the list loads via
    /// `RepositoryStore.fileHistory` (following renames). Set by `ContentView.requestFileHistory`.
    /// ponytail: always follows from HEAD, no branch picker in this mode — a file's history
    /// across an arbitrary branch selection is out of scope here; add a branch parameter to
    /// `fileHistory` if that's ever needed.
    @Binding var fileHistoryPath: String?
    /// The path the currently-selected file-history commit's file had *at that commit* — published
    /// up so `ContentView` can preselect the right file in `CommitDiffView`'s own file list (a
    /// rename means this can differ from `fileHistoryPath` for older entries).
    @Binding var fileHistorySelectedPath: String?

    init(repo: RepositoryStore, selection: Binding<CommitInfo?>, initialBranch: String? = nil,
         initialFilterText: String = "", focusFilterRequested: Binding<Bool> = .constant(false),
         fileHistoryPath: Binding<String?> = .constant(nil),
         fileHistorySelectedPath: Binding<String?> = .constant(nil), initialUnreviewedOnly: Bool = false,
         initialAgentOnly: Bool = false) {
        self.repo = repo
        self._selection = selection
        self.initialBranch = initialBranch
        self._selectedBranch = State(initialValue: initialBranch)
        self.initialFilterText = initialFilterText
        self._filterText = State(initialValue: initialFilterText)
        self.initialUnreviewedOnly = initialUnreviewedOnly
        self._unreviewedOnly = State(initialValue: initialUnreviewedOnly)
        self._agentOnly = State(initialValue: initialAgentOnly)
        self.focusFilterRequested = focusFilterRequested
        self._fileHistoryPath = fileHistoryPath
        self._fileHistorySelectedPath = fileHistorySelectedPath
    }

    private var branchKey: String { selectedBranch ?? repo.repo.branch ?? "HEAD" }
    private var isCurrentBranch: Bool { selectedBranch == nil || selectedBranch == repo.repo.branch }
    /// B7(a): while bisecting, HEAD is detached at whatever commit is under test, so plain "current
    /// branch" (`branch: nil` → `HEAD`) only shows ancestors of that commit — anything newer than it
    /// vanishes from the list. Default instead to the original "bad" ref (`BisectState.bad.first`,
    /// the first `# bad:` line in `git bisect log`) so the full range stays visible; an explicit
    /// pick in the branch picker still overrides this, same as normal.
    private var effectiveBranch: String? {
        if selectedBranch == nil, let bisect = repo.bisect, bisect.isActive, let bad = bisect.bad.first { return bad }
        return selectedBranch
    }
    private var parsedFilter: HistoryFilter { HistoryFilter.parse(filterText) }
    private var filterHint: String? {
        guard let invalid = parsedFilter.invalidDateField else { return nil }
        return "Unrecognized date for \(invalid.label): \"\(invalid.value)\""
    }
    /// The range goes first: `filter.gitArgs` may end with `-- <path>`. A missing review point
    /// falls back to all history (the chip row says so).
    private func gitArgs(_ filter: HistoryFilter) -> [String] {
        var args: [String] = []
        if unreviewedOnly, let reviewed = repo.reviewedHead, !repo.reviewPointMissing { args.append("\(reviewed)..HEAD") }
        // B8: push the "Agent commits" chip into git itself (one `--author` per pattern, git ORs
        // them) instead of filtering only the loaded page — see `AgentProfile.gitAuthorArgs`.
        if agentOnly { args += repo.agentProfile.gitAuthorArgs }
        return args + filter.gitArgs
    }

    var body: some View {
        VStack(spacing: 0) {
            if fileHistoryPath != nil {
                fileHistoryChip
            } else {
                HStack(spacing: 0) { branchPicker; ReflogButton(repo: repo).padding(.trailing, 10) }
                filterField
                reviewRow
            }
            if let bisect = repo.bisect {
                Divider()
                BisectPanel(repo: repo, state: bisect) { hash in Task { await showCommit(hash) } }
            }
            Divider()
            List(selection: $selection) {
                let tagMap = TagParser.byCommit(repo.gitTags)
                let agents = repo.agentProfile
                // `agentOnly` is now enforced server-side (see `gitArgs`), so `commits` is already
                // filtered across every page; `agents.matches` below only drives the row's glyph.
                ForEach(commits) { commit in
                    let isHead = isCurrentBranch && commit.hash == commits.first?.hash
                    let isCherryPickable = cherryPickable.contains(commit.hash)
                    let fileHistoryEntry = fileHistoryEntries.first { $0.commit.hash == commit.hash }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(commit.shortHash).font(.caption.monospaced())
                            if agents.matches(author: commit.author, email: commit.authorEmail) {
                                AgentGlyph()
                            }
                            Text(commit.author)
                            Text(HistoryRowDate.readable(commit.date))
                                .help(HistoryRowDate.absolute(commit.date))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        if let tagNames = tagMap[commit.hash] { TagBadges(names: tagNames) }
                        // Marks exactly the commits the Cherry-pick menu item applies to.
                        // Bisect detaches HEAD mid-branch; its own marks replace this one meanwhile.
                        if isCherryPickable && repo.bisect == nil {
                            Label("not on \(repo.repo.branch ?? "current branch")", systemImage: "circle.fill")
                                .labelStyle(NotOnBranchLabelStyle())
                                .help("Not on your current branch — right-click to cherry-pick it")
                        }
                        BisectRowMark(state: repo.bisect, hash: commit.hash)
                    }
                    .tag(commit)
                    .contextMenu {
                        Button("Copy SHA") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                        }
                        Button("Export as Patch…") { Task { await PatchExport.save(commit, from: repo, toasts: toasts) } }
                        Button("Copy as Patch") { Task { await PatchExport.copy(commit, from: repo, toasts: toasts) } }
                        CommitRefMenuItems(commit: commit, pending: $pendingCommitRef)
                        if !isCherryPickable {
                            Button("Revert Commit…") { pendingRevert = commit }
                        }
                        if isCherryPickable {
                            Button("Cherry-pick onto \(repo.repo.branch ?? "current")…") { pendingCherryPick = commit }
                        }
                        // Undo only ever applies to HEAD — resetting past an older commit would also
                        // discard every commit above it, which is not what "undo" promises here.
                        if let recovery {
                            Divider()
                            Button("Check Out This Commit…") {
                                recovery.requestCheckoutCommit(repo, hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject)
                            }
                            if isCurrentBranch && !isHead && !repo.repo.isDetached {
                                Button("Reset \(repo.repo.branch ?? "Branch") to Here…") {
                                    Task { await recovery.requestReset(repo, to: commit.hash, shortHash: commit.shortHash, subject: commit.subject, toasts: toasts) }
                                }
                            }
                        }
                        if isCurrentBranch && fileHistoryPath == nil && !repo.repo.isDetached {
                            Button("Tidy Commits from Here…") { repoSheets?.active = .interactiveRebase(repo, since: commit.hash) }
                        }
                        if repo.operation == nil {
                            Button("Bisect: Mark as Good…") { repoSheets?.active = .startBisect(repo, good: commit.hash) }
                        } else if repo.bisect != nil {
                            // B7(c): not just the tested commit — any listed commit can be marked
                            // while bisecting (`git bisect good|bad <hash>`).
                            Button("Bisect: Mark Good") { Task { await BisectRunner.mark(.good, hash: commit.hash, on: repo, toasts: toasts) } }
                            Button("Bisect: Mark Bad") { Task { await BisectRunner.mark(.bad, hash: commit.hash, on: repo, toasts: toasts) } }
                        }
                        if isHead {
                            Divider()
                            Button("Undo Commit") { pendingUndo = UndoCommitRunner.request(on: repo, commit: commit, toasts: toasts) }
                                .disabled(repo.isBusy || !repo.hasParentCommit)
                        }
                        // headOID, not `isHead`: a filter can make the first listed row a non-HEAD commit.
                        if let repoSheets, commit.hash == repo.repo.headOID, !repo.repo.isDetached, repo.operation == nil {
                            Button("Reword Commit…") { repoSheets.active = .rewordHead(repo) }
                        }
                        // Only meaningful for a file-history entry — this row's specific path (and
                        // whether this commit *added* it, which decides whether "before" makes
                        // sense) is only known here in file-history mode.
                        if let fileHistoryEntry {
                            Divider()
                            Button("Restore This Version…", systemImage: "arrow.uturn.backward") {
                                pendingRestore = PendingRestore(path: fileHistoryEntry.path, target: .thisCommit(commit))
                            }
                            Button("Restore Version Before This Commit…", systemImage: "arrow.uturn.backward.circle") {
                                pendingRestore = PendingRestore(path: fileHistoryEntry.path, target: .beforeCommit(commit))
                            }
                            .disabled(fileHistoryEntry.kind == .added)
                            .help(fileHistoryEntry.kind == .added ? "This file didn't exist before this commit" : "")
                        }
                    }
                }
                if hasMore {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Load More") { Task { await loadMore() } }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .overlay {
            if isLoading && commits.isEmpty {
                ProgressView()
            } else if commits.isEmpty && filterHint == nil {
                ContentUnavailableView("No commits", systemImage: "clock")
            }
        }
        .task(id: "\(repo.id)-\(repo.repo.lastCommitSummary ?? "")-\(branchKey)-\(filterText)-\(fileHistoryPath ?? "")-\(reviewKey)") {
            // The id also changes when a new commit lands; `lastLoadContext` tells that apart from
            // a real context change (see `HistoryPaging`).
            let context = "\(repo.id)-\(branchKey)-\(filterText)-\(fileHistoryPath ?? "")-\(reviewKey)"
            let sameContext = context == lastLoadContext
            lastLoadContext = context
            isLoading = true
            defer { isLoading = false }
            if let fileHistoryPath {
                let limit = HistoryPaging.limit(sameContext: sameContext, currentCount: commits.count, pageSize: historyPageSize)
                let loaded = await repo.fileHistory(path: fileHistoryPath, limit: limit)
                fileHistoryEntries = loaded
                commits = loaded.map(\.commit)
                cherryPickable = []
                hasMore = loaded.count == limit
                // Auto-select the most recent version — the point of opening file history is to
                // see it right away, not to make the user click the first row too.
                if selection == nil || !commits.contains(where: { $0.hash == selection?.hash }) {
                    selection = commits.first
                }
                return
            }
            fileHistoryEntries = []
            // Built-in debounce + cancel: `.task(id:)` cancels the in-flight task and starts a
            // fresh one whenever `id` changes, so a keystroke 100ms later than the last one simply
            // restarts the sleep below rather than racing two queries against each other.
            if !filterText.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            let filter = parsedFilter
            guard filter.invalidDateField == nil else {
                commits = []
                cherryPickable = []
                hasMore = false
                return
            }
            let limit = HistoryPaging.limit(sameContext: sameContext, currentCount: commits.count, pageSize: historyPageSize)
            // Both computed before either is published, so the context menu never offers Revert on
            // a not-yet-classified commit that isn't on this branch.
            let loaded = await repo.history(limit: limit, branch: effectiveBranch, filterArgs: gitArgs(filter))
            let notOnHead = isCurrentBranch ? [] : await repo.commitsNotReachableFromHead(branchKey)
            commits = loaded
            cherryPickable = notOnHead
            hasMore = loaded.count == limit
        }
        .task(id: "\(repo.id)-\(repo.repo.lastCommitSummary ?? "")") { await repo.refreshTags() }
        .modifier(CommitRefDialogs(repo: repo, pending: $pendingCommitRef))
        .onChange(of: repo.id) { selectedBranch = nil; filterText = ""; unreviewedOnly = false; fileHistoryPath = nil; fileHistorySelectedPath = nil }
        .onChange(of: focusFilterRequested.wrappedValue) { _, requested in
            guard requested else { return }
            filterFocused = true
            focusFilterRequested.wrappedValue = false
        }
        // Keeps `fileHistorySelectedPath` in sync with whichever file-history row is selected, so
        // `ContentView` can hand `CommitDiffView` the right path to preselect for that specific
        // commit (a rename means it can differ from `fileHistoryPath` itself for older rows).
        .onChange(of: selection) { _, newValue in
            guard fileHistoryPath != nil else { return }
            fileHistorySelectedPath = fileHistoryEntries.first { $0.commit.hash == newValue?.hash }?.path
        }
        .confirmationDialog(
            pendingRestore.map(RestoreFileRunner.confirmTitle) ?? "Restore file?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let pending = pendingRestore { Task { await RestoreFileRunner.perform(pending, on: repo, toasts: toasts) } }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text(pendingRestore.map {
                RestoreFileRunner.confirmMessage(for: $0, hasUncommittedChanges: RestoreFileConfirmation.hasUncommittedChanges(path: $0.path, in: repo.repo.changes))
            } ?? "")
        }
        .modifier(UndoCommitDialogs(pending: $pendingUndo))
        .modifier(CommitPickDialogs(pendingRevert: $pendingRevert, pendingCherryPick: $pendingCherryPick, repo: repo))
    }

    /// Local branches first, then remote — default selection (nil) is the current branch. Resets to
    /// the current branch whenever the repository changes (see `onChange(of: repo.id)` above).
    /// A popover list rather than a `Picker`, which built a menu item per branch on every pass.
    private var branchPicker: some View {
        let current = selectedBranch ?? repo.repo.branch ?? ""
        // Detached HEAD matches no branch — without this entry the list has nothing checked.
        let detached = repo.repo.isDetached ? repo.repo.branch.map { [BranchListPopover<EmptyView>.Extra(value: $0, label: repo.repo.branchLabel)] } : nil
        return BranchPickerButton(
            title: repo.repo.isDetached && current == repo.repo.branch ? repo.repo.branchLabel : current,
            branches: repo.branches,
            selection: current,
            leading: detached ?? [],
            onPick: { newValue in selectedBranch = newValue == repo.repo.branch ? nil : newValue }
        )
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// Free text matches subject/body; `author:`, `path:`, `since:`, `until:` tokens map to git's
    /// own options (see `HistoryFilter`). An invalid `since`/`until` shows an inline hint instead
    /// of silently returning an empty list — git itself never errors on a bad date (verified
    /// against real git output), so there's no error to surface without validating it ourselves.
    private var filterField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Filter (author:, path:, since:, until:)", text: $filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
            if let filterHint {
                Text(filterHint)
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.bottom, 6)
    }

    private var reviewKey: String { unreviewedOnly ? "unreviewed:\(repo.reviewedHead ?? "")-\(repo.reviewPointMissing)" : "" }

    /// "Unreviewed" chip (once a review point exists) plus "Mark Reviewed up to HEAD".
    private var reviewRow: some View {
        HStack(spacing: 8) {
            if repo.reviewedHead != nil {
                Toggle(isOn: $unreviewedOnly) {
                    HStack(spacing: 4) {
                        Text("Unreviewed")
                        if let count = repo.unreviewedCount {
                            Text("\(count)").monospacedDigit()
                                .padding(.horizontal, 5)
                                .background(Theme.brand.opacity(0.2), in: Capsule())
                        }
                    }
                }
                .toggleStyle(.button).controlSize(.small)
                .help("Only commits since you last marked this repository reviewed")
                if repo.reviewPointMissing {
                    Text("Review point is gone — showing all history")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Toggle(isOn: $agentOnly) { Label("Agent commits", systemImage: "cpu") }
                .toggleStyle(.button).controlSize(.small)
                .help("Only commits whose author matches the agent patterns (Settings → Agents)")
            Spacer(minLength: 0)
            Button("Mark Reviewed up to HEAD", systemImage: "checkmark.circle") { repo.markReviewed() }
                .controlSize(.small)
                .disabled(repo.repo.headOID == nil || (repo.reviewedHead == repo.repo.headOID && !repo.reviewPointMissing))
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    /// Replaces `branchPicker` + `filterField` in file-history mode. Clearing it goes
    /// back to ordinary history (`ContentView` doesn't need to know; this view owns the binding).
    private var fileHistoryChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Theme.brand)
            Text("File: \(fileHistoryPath ?? "")")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Button {
                fileHistoryPath = nil
                fileHistorySelectedPath = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to full history")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.brand.opacity(0.12))
    }

    /// Bisect's "Show": selects the commit even when it isn't in the loaded page (HEAD is detached
    /// at the last tested commit, so the first bad one can sit above it).
    private func showCommit(_ hash: String) async {
        if let loaded = commits.first(where: { $0.hash == hash }) { selection = loaded } else { selection = await repo.commitInfo(hash) }
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let fileHistoryPath {
            let next = await repo.fileHistory(path: fileHistoryPath, limit: historyPageSize, skip: fileHistoryEntries.count)
            fileHistoryEntries += next
            commits += next.map(\.commit)
            hasMore = next.count == historyPageSize
            return
        }
        let filter = parsedFilter
        guard filter.invalidDateField == nil else { return }
        let next = await repo.history(limit: historyPageSize, skip: commits.count, branch: effectiveBranch, filterArgs: gitArgs(filter))
        commits += next
        hasMore = next.count == historyPageSize
    }
}

/// Small brand-tinted dot + caption for "not on <current>" in the history list.
private struct NotOnBranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(Theme.brand)
            configuration.title.font(.caption2.weight(.medium)).foregroundStyle(Theme.brand)
        }
        .lineLimit(1)
    }
}
