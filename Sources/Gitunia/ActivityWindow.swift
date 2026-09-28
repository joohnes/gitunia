import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GituniaCore

/// The `Window("Activity", id: "activity")` scene root: "what happened while I wasn't looking",
/// across every open workspace (they all share `registry.app.activity`).
struct ActivityWindow: View {
    var registry: WorkspaceRegistry

    var body: some View {
        ActivityView(log: registry.app.activity, registry: registry)
            .frame(minWidth: 760, minHeight: 440)
    }
}

/// A remote branch nobody has touched in `ActivityView.staleDays`, or already merged into base.
struct StaleBranch: Identifiable, Equatable {
    var id: String { ref }
    let ref: String
    let lastCommit: Date
    let author: String
    let merged: Bool
}

enum ActivityRange: String, CaseIterable, Identifiable {
    case today = "Today", day = "24h", week = "7 days", month = "30 days"
    var id: String { rawValue }
    func since(now: Date = Date()) -> Date {
        switch self {
        case .today: return Calendar.current.startOfDay(for: now)
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        }
    }
}

struct ActivityView: View {
    static let staleDays = 14

    var log: ActivityLog
    /// nil in render tests — row actions that need an open workspace then do nothing.
    var registry: WorkspaceRegistry?
    @Environment(\.openWindow) private var openWindow
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var range: ActivityRange
    @State private var search = ""
    /// `allTag` (or nil) = "All repositories"; else an `ActivityEvent.repoPath`. A real tag rather than
    /// nil so the "All repositories" row shows as selected.
    @State private var listSelection: String?
    private var selection: String? { listSelection == Self.allTag ? nil : listSelection }
    private static let allTag = "all-repositories"
    /// Per repo, loaded once per window open (on first selection).
    @State private var stale: [String: [StaleBranch]]
    @State private var pendingDelete: (repoPath: String, branch: StaleBranch)?
    /// The selected repo's store + `owner/repo` when it can post via gh; nil otherwise (button disabled).
    @State private var gitHubPost: (store: RepositoryStore, slug: String)?
    @State private var showingPost = false

    init(log: ActivityLog, registry: WorkspaceRegistry? = nil, range: ActivityRange = .week,
         selection: String? = nil, preloadedStale: [String: [StaleBranch]] = [:]) {
        self.log = log
        self.registry = registry
        _range = State(initialValue: range)
        _listSelection = State(initialValue: selection ?? Self.allTag)
        _stale = State(initialValue: preloadedStale)
    }

    private var since: Date { range.since() }
    private var digest: [ActivityDigestRepo] { log.digest(since: since, agents: registry?.app.settings.agentProfile ?? AgentProfile()) }
    private var scopedDigest: [ActivityDigestRepo] { digest.filter { selection == nil || $0.repoPath == selection } }

    private var visibleEvents: [ActivityEvent] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return scopedDigest.flatMap(\.events)
            .filter { e in
                q.isEmpty || e.ref.localizedCaseInsensitiveContains(q)
                    || (e.pullRequestTitle?.localizedCaseInsensitiveContains(q) ?? false)
                    || e.commits.contains { $0.subject.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
            }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                repoList.frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
                timeline.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // ponytail: fixed 2 s dwell before a repo's events count as seen.
        .task(id: selection) {
            guard let path = selection else { return }
            if stale[path] == nil, let store = repoStore(path) { stale[path] = await Self.loadStale(store) }
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            log.markSeen(repoPath: path)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete on Remote", role: .destructive) { if let p = pendingDelete { delete(p.branch, in: p.repoPath) } }
        } message: {
            Text("Every clone tracking this branch loses it on its next fetch. Local branches are not touched.")
        }
        .task(id: selection) {
            gitHubPost = nil
            guard let path = selection, let store = repoStore(path), await store.supportsGitHubPost(),
                  let slug = await store.gitHubSlug() else { return }
            gitHubPost = (store, slug)
        }
        .sheet(isPresented: $showingPost) {
            if let target = gitHubPost {
                PostReportSheet(store: target.store, slug: target.slug, report: report,
                                rangeLabel: "\(since.formatted(date: .abbreviated, time: .omitted)) – \(Date().formatted(date: .abbreviated, time: .omitted))",
                                toasts: toasts)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(ActivityRange.allCases) { r in
                    Button(r.rawValue) { range = r }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(range == r ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
                        .foregroundStyle(range == r ? Color.accentColor : .primary)
                }
            }
            TextField("Search refs, commits, authors, PRs", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 280)
            Spacer()
            Button("Mark All as Seen") { log.markSeen() }
                .disabled(log.unseenCount == 0)
            Button("Copy Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                toasts?.post(.success("Activity report copied"))
            }
            Button("Save Report…", action: saveReport)
            Button("Post to GitHub…") { showingPost = true }
                .disabled(gitHubPost == nil)
                .help(gitHubPost != nil ? "Post this report as a PR comment or a new issue"
                      : selection == nil ? "Select a single repository" : "Needs gh and a github.com origin")
        }
        .padding(10)
    }

    private var report: String { ActivityLog.markdown(scopedDigest, since: since) }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Activity \(Date().formatted(.iso8601.year().month().day())).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8) }
        catch { toasts?.post(.error("Couldn't save report", detail: error.localizedDescription)) }
    }

    // MARK: - Repo column

    private var repoList: some View {
        List(selection: $listSelection) {
            HStack {
                Label("All repositories", systemImage: "square.stack.3d.up")
                Spacer()
                if log.events.contains(where: { !$0.seen && $0.date >= since }) { unseenDot }
            }
            .tag(Optional(Self.allTag))
            .id(Self.allTag)
            ForEach(digest, id: \.repoPath) { repo in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(repo.repoName).fontWeight(.medium)
                        Spacer()
                        if repo.events.contains(where: { !$0.seen }) { unseenDot }
                    }
                    Text(counts(repo)).font(.caption).foregroundStyle(.secondary)
                    if repo.newCommits > 0 {
                        Text("\(repo.agentCommits) by agents · \(repo.humanCommits) by you").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(Optional(repo.repoPath))
            }
        }
        .listStyle(.sidebar)
    }

    private var unseenDot: some View { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }

    private func counts(_ r: ActivityDigestRepo) -> String {
        var parts: [String] = []
        if r.mergedPRs > 0 { parts.append("\(r.mergedPRs) PR\(r.mergedPRs == 1 ? "" : "s") merged") }
        if r.newCommits > 0 { parts.append("\(r.newCommits) commit\(r.newCommits == 1 ? "" : "s")") }
        if r.branchesCreated + r.branchesDeleted > 0 { parts.append("+\(r.branchesCreated) −\(r.branchesDeleted) branches") }
        return parts.isEmpty ? "\(r.events.count) event\(r.events.count == 1 ? "" : "s")" : parts.joined(separator: " · ")
    }

    // MARK: - Timeline

    private var timeline: some View {
        let events = visibleEvents
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        return List {
            if events.isEmpty {
                Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            ForEach(days, id: \.key) { day, dayEvents in
                Section(day.formatted(date: .complete, time: .omitted)) {
                    ForEach(dayEvents) { ActivityEventRow(event: $0, showsRepo: selection == nil, actions: self) }
                }
            }
            if let path = selection { staleSection(path) }
        }
    }

    private var emptyText: String {
        if registry?.app.settings.trackRemoteActivity == false { return "Remote activity tracking is off (Settings)." }
        return search.isEmpty ? "No remote activity in this range." : "Nothing matches “\(search)”."
    }

    @ViewBuilder
    private func staleSection(_ path: String) -> some View {
        Section("Stale branches — no commits in \(Self.staleDays) days, or merged") {
            if let branches = stale[path] {
                if branches.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(branches) { b in
                    HStack {
                        Image(systemName: b.merged ? "arrow.triangle.merge" : "clock.badge.exclamationmark")
                            .foregroundStyle(.secondary).frame(width: 18)
                        Text(b.ref).font(.body.monospaced())
                        if b.merged { Text("merged").font(.caption).padding(.horizontal, 5).background(Capsule().fill(.green.opacity(0.18))) }
                        Spacer()
                        Text("\(b.author) · \(b.lastCommit.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Delete on Remote…") { pendingDelete = (path, b) }
                            .controlSize(.small)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var deleteTitle: String {
        guard let p = pendingDelete else { return "" }
        let (remote, branch) = Self.split(p.branch.ref)
        return "Delete “\(branch)” on \(remote)?"
    }

    /// `"origin/feat/x"` → `("origin", "feat/x")`.
    static func split(_ ref: String) -> (remote: String, branch: String) {
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : ("origin", ref)
    }

    static func loadStale(_ store: RepositoryStore, now: Date = Date()) async -> [StaleBranch] {
        let base = await store.defaultBaseBranch().map { $0.hasPrefix("origin/") ? $0 : "origin/\($0)" }
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        return await store.remoteBranchAges()
            .filter { $0.ref != base && ($0.mergedIntoBase || $0.lastCommit < cutoff) }
            .map { StaleBranch(ref: $0.ref, lastCommit: $0.lastCommit, author: $0.author, merged: $0.mergedIntoBase) }
    }

    private func delete(_ b: StaleBranch, in path: String) {
        guard let store = repoStore(path) else { return }
        let (remote, branch) = Self.split(b.ref)
        Task {
            if await store.deleteRemoteBranch(branch, remote: remote) {
                stale[path]?.removeAll { $0.ref == b.ref }
                toasts?.post(.success("Deleted \(branch) on \(remote)"))
            } else {
                toasts?.post(.error("Couldn't delete \(branch) on \(remote)", detail: store.lastError?.localizedDescription))
            }
        }
    }

    // MARK: - Row actions

    /// The first open window (in window order) whose workspace has this repo.
    private func locate(_ path: String) -> (UUID, WorkspaceStore, RepositoryStore)? {
        registry?.window(containing: path)
    }

    /// An open store for `path`, else a throwaway one (the repo isn't in any open workspace).
    private func repoStore(_ path: String) -> RepositoryStore? {
        if let (_, _, repo) = locate(path) { return repo }
        return FileManager.default.fileExists(atPath: path) ? RepositoryStore(url: URL(fileURLWithPath: path)) : nil
    }

    func openRepository(_ path: String) {
        guard let (id, ws, repo) = locate(path) else {
            toasts?.post(.info("Not in any open workspace", detail: path))
            return
        }
        ws.select(repo)
        openWindow(value: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Jumps History to the commit via `HistoryNavigator`; with the repo in no open window, copies
    /// the hash instead.
    func showCommit(_ commit: ActivityCommit, repoPath: String) {
        if let registry, let (_, _, repo) = locate(repoPath), registry.navigator.show(commit: commit.hash, in: repo) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
        toasts?.post(.info("Copied \(commit.hash.prefix(7))", detail: "The repository isn't in any open workspace."))
    }

    func canOpenPullRequest(_ e: ActivityEvent) -> Bool {
        e.pullRequestNumber != nil && locate(e.repoPath)?.2.hasGitHubRemote != false
    }

    func openPullRequest(_ e: ActivityEvent) {
        guard let number = e.pullRequestNumber, let store = repoStore(e.repoPath) else { return }
        Task {
            let origin = await store.listRemotes().first { $0.name == "origin" }?.fetchURL ?? ""
            if let url = GitHubURL.pull(remoteURL: origin, number: number) { NSWorkspace.shared.open(url) }
            else { toasts?.post(.error("origin isn't a GitHub remote", detail: origin)) }
        }
    }
}

struct ActivityEventRow: View {
    let event: ActivityEvent
    let showsRepo: Bool
    let actions: ActivityView
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(event.kind))
                    .foregroundStyle(Self.tint(event.kind))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Self.tint(event.kind).opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(event)).fontWeight(event.seen ? .regular : .bold).lineLimit(1)
                    if showsRepo { Text(event.repoName).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(event.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                if !event.commits.isEmpty {
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }
                        .buttonStyle(.borderless)
                }
                Menu {
                    menuItems
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if expanded {
                ForEach(event.commits) { c in
                    HStack(spacing: 8) {
                        Text(c.hash.prefix(7)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(c.subject).font(.callout).lineLimit(1)
                        Spacer()
                        Text(c.author).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 30)
                    .contextMenu { Button("Show Commit in History") { actions.showCommit(c, repoPath: event.repoPath) } }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open Repository") { actions.openRepository(event.repoPath) }
        if let first = event.commits.first {
            Button("Show Commit in History") { actions.showCommit(first, repoPath: event.repoPath) }
        }
        if actions.canOpenPullRequest(event) {
            Button("Open Pull Request") { actions.openPullRequest(event) }
        }
    }

    static func title(_ e: ActivityEvent) -> String {
        if e.kind == .pullRequestMerged {
            return "Merged #\(e.pullRequestNumber ?? 0)" + (e.pullRequestTitle.map { " · \($0)" } ?? "")
        }
        let verb: String
        switch e.kind {
        case .branchCreated: verb = "New "
        case .branchDeleted: verb = "Deleted "
        case .forcePushed: verb = "Force-pushed "
        default: verb = ""
        }
        let n = e.commits.count
        guard n > 0 else { return verb + e.ref }
        let authors = Array(Set(e.commits.map(\.author))).sorted().joined(separator: ", ")
        return "\(verb)\(e.ref) · \(n) commit\(n == 1 ? "" : "s") by \(authors)"
    }

    static func icon(_ k: ActivityEventKind) -> String {
        switch k {
        case .pullRequestMerged: return "arrow.triangle.merge"
        case .forcePushed: return "exclamationmark.arrow.triangle.2.circlepath"
        case .branchDeleted: return "trash"
        case .baseAdvanced: return "arrow.up.circle"
        case .branchCreated: return "plus.circle"
        case .branchUpdated: return "arrow.up.right.circle"
        }
    }

    static func tint(_ k: ActivityEventKind) -> Color {
        switch k {
        case .pullRequestMerged: return .green
        case .forcePushed: return .red
        case .branchDeleted: return .gray
        case .baseAdvanced: return .accentColor
        case .branchCreated: return .blue
        case .branchUpdated: return .secondary
        }
    }
}
