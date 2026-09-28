import Foundation
import Observation

/// The sidebar's scope selector: which repositories `visibleRepositories` shows before the search
/// query narrows it further. Replaces the old ad-hoc `tagFilter: String?` (nil meant "all") so
/// "changed" — the question the user actually asks when supervising agents — is a first-class
/// case instead of something the sort toggle only approximated.
public enum RepoScope: Hashable, Sendable {
    case all
    case changed
    /// Stopped mid-operation (rebase/merge/cherry-pick/revert) or holding conflicted files.
    case attention
    case tag(String)
}

public enum RepoSort: String, Sendable, CaseIterable {
    case name = "Name"
    case changedFirst = "Changed first"
    case recent = "Recent activity"
}

/// One scope chip's label and live count, for the sidebar header row. Pure data — the view just
/// renders it.
public struct ScopeChip: Identifiable, Hashable, Sendable {
    public let scope: RepoScope
    public let label: String
    public let count: Int
    public var id: RepoScope { scope }
}

public enum WorkspaceStoreError: LocalizedError, Equatable {
    case notARepository(String)
    public var errorDescription: String? {
        switch self {
        case .notARepository(let name):
            return "“\(name)” isn't a git repository. To add the repositories inside a folder, use Add Repos in Folder…"
        }
    }
}

/// One open `.gitunia-workspace` file: its single repos and linked folders resolved into
/// `repositories`. Global state (settings, per-repo prefs, windows, recents) lives in `app`, shared
/// by every window; only tags are per-workspace and are written to the file.
@MainActor
@Observable
public final class WorkspaceStore {
    public let app: AppConfig
    public private(set) var fileURL: URL?
    public private(set) var file = WorkspaceFile()
    public private(set) var repositories: [RepositoryStore] = []
    public private(set) var missingPaths: [String] = []
    public private(set) var missingFolders: [String] = []
    /// Linked folder → repos its last scan found (for Manage Workspace counts).
    public internal(set) var folderScans: [String: [String]] = [:]
    /// Set from many places (the sidebar's List binding, the palette, restoration), so marking the
    /// repo as viewed hangs off the property rather than `select(_:)`.
    public var selectedRepoID: URL? {
        didSet { if let store = repositories.first(where: { $0.id == selectedRepoID }) { markViewed(store) } }
    }
    public var scope: RepoScope = .all
    public var sort: RepoSort = .changedFirst
    public var searchQuery: String = ""
    public private(set) var isScanning = false
    public internal(set) var bulk: BulkOperation?
    /// True for the duration of any bulk sweep (visible or silent auto-fetch), so a silent
    /// auto-fetch tick and a user-triggered Pull/Push/Fetch All never run concurrently over the
    /// same repos (concurrent git invocations on one repo can collide on git's index lock).
    var bulkInFlight = false
    /// Last failed write of the workspace file (nil after a successful one) — the UI toasts it.
    public private(set) var saveError: String?
    /// Every member repo's `RepoEvent`s (commits, new branches, stopped operations, rescan joins).
    @ObservationIgnored public var onRepoEvents: ((RepositoryStore, [RepoEvent]) -> Void)?

    public var config: WorkspaceConfig { app.config }
    /// Set when `workspace.json` had to be reset because it was corrupt — see `AppConfig.loadWarning`.
    public var configLoadWarning: String? { app.loadWarning }
    public var isUntitled: Bool { fileURL.map(app.isUntitled) ?? true }
    public var displayName: String {
        guard let fileURL, !isUntitled else { return "Untitled Workspace" }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    var watcher: FSEventsWatcher?
    var pendingRefresh: [URL: Task<Void, Never>] = [:]
    var pendingRescan: [String: Task<Void, Never>] = [:]
    private let saver = Debouncer()
    var autoFetchTask: Task<Void, Never>?
    /// Auto-fetch ticks since launch; `isFetchDue` turns it into per-cadence fetches.
    var autoFetchTick = 0
    private var draftSavers: [URL: Debouncer] = [:]
    private let draftDebounce: Duration
    private let saveDebounce: Duration

    public init(app: AppConfig, draftDebounce: Duration = .seconds(1), saveDebounce: Duration = .milliseconds(500)) {
        self.app = app
        self.draftDebounce = draftDebounce
        self.saveDebounce = saveDebounce
        app.attach(self)
    }

    /// Tests and previews: a store with its own `AppConfig` over `configStore`.
    public convenience init(configStore: ConfigStore = ConfigStore(), draftDebounce: Duration = .seconds(1)) {
        self.init(app: AppConfig(configStore: configStore), draftDebounce: draftDebounce)
    }

    /// Call once the UI has shown `configLoadWarning` to the user.
    public func dismissConfigLoadWarning() { app.dismissLoadWarning() }

    // MARK: - Derived

    public var visibleRepositories: [RepositoryStore] {
        var list = repositories
        switch scope {
        case .all: break
        case .changed: list = list.filter { WorkspaceStore.isChanged($0.repo) }
        case .attention: list = list.filter(\.needsAttention)
        case .tag(let tag): list = list.filter { $0.repo.tags.contains(tag) }
        }
        if searchQuery.isEmpty {
            list.sort { a, b in
                if sort == .changedFirst, WorkspaceStore.isChanged(a.repo) != WorkspaceStore.isChanged(b.repo) {
                    return WorkspaceStore.isChanged(a.repo)
                }
                if sort == .recent, a.lastActivity != b.lastActivity {
                    return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
                }
                return a.repo.name.localizedCaseInsensitiveCompare(b.repo.name) == .orderedAscending
            }
        } else {
            // Searching: relevance order from FuzzyMatch takes over from the sort menu, same as
            // the command palette — the chosen sort is a browsing preference, not something you
            // want fighting a search you're actively typing.
            list = FuzzyMatch.rank(list, query: searchQuery) { $0.repo.name }
        }
        return list
    }

    /// `repos` (already filtered/sorted) with each linked worktree moved right after its main repo
    /// at depth 1, keeping their relative order. A worktree whose main repo isn't in `repos`
    /// (filtered out, or not in the workspace) stays top-level where it was.
    public static func sidebarOrder(_ repos: [RepositoryStore]) -> [(repo: RepositoryStore, depth: Int)] {
        let keys = repos.map { $0.url.resolvingSymlinksInPath().path }
        let present = Set(keys)
        func parentKey(_ r: RepositoryStore) -> String? {
            r.worktreeParent.map(\.path).flatMap { present.contains($0) ? $0 : nil }
        }
        var out: [(repo: RepositoryStore, depth: Int)] = []
        for (repo, key) in zip(repos, keys) where parentKey(repo) == nil {
            out.append((repo, 0))
            out += repos.filter { parentKey($0) == key }.map { ($0, 1) }
        }
        return out
    }

    /// "Changed" is the question the user actually asks when supervising agents: did anything
    /// happen here, whether that's an uncommitted edit or commits waiting to push/pull.
    public nonisolated static func isChanged(_ repo: Repository) -> Bool {
        repo.hasChanges || repo.ahead > 0 || repo.behind > 0
    }

    public var changedRepositories: [RepositoryStore] { repositories.filter { WorkspaceStore.isChanged($0.repo) } }
    public var changedRepoCount: Int { changedRepositories.count }
    public var allTags: [String] { Array(Set(repositories.flatMap { $0.repo.tags })).sorted() }
    public var selectedRepository: RepositoryStore? { repositories.first { $0.id == selectedRepoID } }

    /// Scope chips for the sidebar header, in display order: All, Changed, Attention, then one per tag.
    public var scopeChips: [ScopeChip] {
        var chips = [
            ScopeChip(scope: .all, label: "All", count: repositories.count),
            ScopeChip(scope: .changed, label: "Changed", count: changedRepoCount),
            ScopeChip(scope: .attention, label: "Attention", count: repositories.filter(\.needsAttention).count),
        ]
        for tag in allTags {
            chips.append(ScopeChip(scope: .tag(tag), label: tag, count: repositories.filter { $0.repo.tags.contains(tag) }.count))
        }
        return chips
    }

    // MARK: - Workspace lifecycle

    public func open(fileURL url: URL) async throws {
        let loaded = try WorkspaceFile.load(from: url)
        stopWatching()
        fileURL = url.standardizedFileURL
        file = loaded
        repositories = []
        app.noteRecent(url)
        await loadAndWatch()
    }

    /// A fresh untitled workspace, optionally with `folder` linked (what migration and tests use).
    public func openUntitled(linkingFolder folder: URL? = nil) async {
        stopWatching()
        fileURL = app.newUntitledURL()
        file = WorkspaceFile()
        if let folder { file.linkFolder(WorkspaceFile.standardize(folder.path)) }
        repositories = []
        writeFile()
        await loadAndWatch()
    }

    private func loadAndWatch() async {
        // Watcher first (A3): paths come from `file.folders`/`file.repositories`, known before the
        // scan, so a file written while `refreshAll` is still in flight isn't missed until the next
        // unrelated FSEvent. `handleChanges` already tolerates events for repos not yet in
        // `repositories` (routes them to a folder rescan), and `rescan` guards against racing the
        // membership rebuild this `refreshAll` is doing.
        startWatching()
        await refreshAll()
        if selectedRepoID == nil { selectedRepoID = visibleRepositories.first?.id }
        startAutoFetch()
    }

    public func saveAs(_ url: URL) throws {
        let old = fileURL, wasUntitled = isUntitled
        try file.save(to: url, relativePaths: true)
        saver.cancel()
        saveError = nil
        fileURL = url.standardizedFileURL
        if let old { app.workspaceMoved(from: old, to: url) }
        if wasUntitled, let old { try? FileManager.default.removeItem(at: old) }
        app.noteRecent(url)
    }

    /// Writes a pending debounced save now.
    public func flushSave() { saver.flush() }

    private func fileDidChange() {
        saver.schedule(saveDebounce) { [weak self] in self?.writeFile() }
    }

    private func writeFile() {
        guard let fileURL else { return }
        do {
            try file.save(to: fileURL, relativePaths: !isUntitled)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Rescans the linked folders and refreshes every repo. Global prefs are never pruned here —
    /// they are shared with other workspaces.
    public func refreshAll() async {
        guard fileURL != nil else { return }
        isScanning = true
        let folders = file.folders.map(\.path)
        let scans = await Task.detached {
            var out: [String: [String]] = [:]
            for folder in folders where FileManager.default.fileExists(atPath: folder) {
                out[folder] = WorkspaceScanner.findRepositories(in: URL(fileURLWithPath: folder)).map { $0.standardizedFileURL.path }
            }
            return out
        }.value
        folderScans = scans
        applyMembership()
        // Concurrent, not one repo after another: a 30-repo workspace used to take a linear
        // second-plus to come alive on every open. The spinner stays up until the statuses land,
        // otherwise the sidebar shows branchless rows with no hint that data is still arriving.
        // Unstructured tasks rather than a `TaskGroup`: a group whose children call back into these
        // `@MainActor` stores trips the region-isolation checker ("pattern ... does not understand").
        // Chunked so a 40-repo workspace doesn't fork 160 git processes (4 per refresh) at once.
        // ponytail: fixed chunk of 8, a proper semaphore if the chunk tail shows as idle time.
        let repos = repositories
        for start in stride(from: 0, to: repos.count, by: 8) {
            let tasks = repos[start..<min(start + 8, repos.count)].map { repo in Task { await repo.refreshStatus() } }
            for task in tasks { await task.value }
        }
        persistUnseenBaselines(for: repos)
        isScanning = false
    }

    /// A5: `RepositoryStore.refreshStatus` sets `lastViewedFingerprint` in memory (no per-repo write)
    /// the first time a repo has never been viewed, so the unseen dot has a baseline right away
    /// instead of only after the user first clicks the repo. Persisting that baseline is this
    /// method's job — once per batch of repos, not once per repo, so opening a 40-repo workspace
    /// doesn't rewrite `workspace.json` 40 times. Skips the selected repo: `fingerprintDidChange` /
    /// `markViewed` already persists it (and it must never show a dot to begin with).
    func persistUnseenBaselines(for repos: [RepositoryStore]) {
        let batch: [(path: String, change: (inout RepoPrefs) -> Void)] = repos.compactMap { repo in
            guard repo.id != selectedRepoID, let baseline = repo.lastViewedFingerprint,
                  app.prefs(for: repo.url.path).lastViewedFingerprint == nil
            else { return nil }
            let path = repo.url.path
            return (path, { $0.lastViewedFingerprint = baseline })
        }
        app.updatePrefs(batch: batch)
    }

    /// Rebuilds `repositories` from `file` + the latest scans, reusing existing stores by path.
    func applyMembership() {
        let result = WorkspaceMembership.resolve(file, scans: folderScans) { FileManager.default.fileExists(atPath: $0) }
        var byPath = Dictionary(uniqueKeysWithValues: repositories.map { ($0.url.standardizedFileURL.path, $0) })
        repositories = result.present.map { entry in
            if let existing = byPath.removeValue(forKey: entry.path) { return existing }
            let store = RepositoryStore(url: URL(fileURLWithPath: entry.path), prefs: prefs(for: entry.path))
            store.onEvents = { [weak self, weak store] events in
                if let self, let store { self.onRepoEvents?(store, events) }
            }
            store.onFingerprintChange = { [weak self] in self?.fingerprintDidChange($0) }
            store.onMarkReviewed = { [weak self] store in
                self?.app.updatePrefs(for: store.url.path) { $0.reviewedHead = store.reviewedHead }
            }
            store.onRemoteActivity = { [weak self, weak store] events in
                self?.app.activity.append(events)
                if let self, let store { self.onRepoEvents?(store, events.map(RepoEvent.remoteActivity)) }
            }
            syncActivityTracking(store)
            return store
        }
        missingPaths = result.missing
        missingFolders = result.missingFolders
        if let selectedRepoID, !repositories.contains(where: { $0.id == selectedRepoID }) {
            self.selectedRepoID = visibleRepositories.first?.id
        }
        if case .tag(let tag) = scope, !allTags.contains(tag) { scope = .all }
    }

    /// Global prefs with this workspace's tags for `path` layered on.
    private func prefs(for path: String) -> RepoPrefs {
        var p = app.prefs(for: path)
        p.tags = file.tags[path] ?? []
        return p
    }

    private func entry(for repo: RepositoryStore) -> WorkspaceMembership.Entry? {
        let path = repo.url.standardizedFileURL.path
        return WorkspaceMembership.resolve(file, scans: folderScans, exists: { _ in true }).present.first { $0.path == path }
    }

    // MARK: - Membership

    @discardableResult
    public func addRepository(_ url: URL) async throws -> RepositoryStore {
        let top = (try? await GitRunner().run(["rev-parse", "--show-toplevel"], in: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !top.isEmpty else { throw WorkspaceStoreError.notARepository(url.lastPathComponent) }
        // git reports the realpath (/private/var/…); keep the path the user picked when it's the same repo.
        let path = URL(fileURLWithPath: top).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
            ? WorkspaceFile.standardize(url.path) : WorkspaceFile.standardize(top)
        if repository(atPath: path) == nil {
            file.addRepository(path)
            fileDidChange()
            applyMembership()
            restartWatching()
        }
        guard let store = repository(atPath: path) else { throw WorkspaceStoreError.notARepository(url.lastPathComponent) }
        await store.refreshStatus()
        select(store)
        return store
    }

    public func addFolder(_ url: URL) async {
        file.linkFolder(WorkspaceFile.standardize(url.path))
        fileDidChange()
        await refreshAll()
        restartWatching()
    }

    public func remove(_ repo: RepositoryStore) -> WorkspaceRemoval? {
        guard let entry = entry(for: repo) else { return nil }
        let removal = file.remove(entry)
        fileDidChange()
        applyMembership()
        restartWatching()
        return removal
    }

    public func undo(_ removal: WorkspaceRemoval) async {
        file.undo(removal)
        fileDidChange()
        applyMembership()
        restartWatching()
        for repo in repositories where repo.repo.branch == nil { await repo.refreshStatus() }
    }

    public func removeMissing(_ path: String) {
        file.repositories.removeAll { $0 == path }
        fileDidChange()
        applyMembership()
    }

    public func unlinkFolder(_ path: String) async {
        file.unlinkFolder(path)
        folderScans[path] = nil
        fileDidChange()
        applyMembership()
        restartWatching()
    }

    public func restoreExcluded(folder: String, relative: String) async {
        file.restoreExcluded(folder: folder, relative: relative)
        fileDidChange()
        applyMembership()
        for repo in repositories where repo.repo.branch == nil { await repo.refreshStatus() }
    }

    // MARK: - Prefs

    /// Tags belong to the workspace file (keyed by standardized path); every other pref is global,
    /// keyed by `repo.url.path`, so it follows the repo into any workspace.
    public func setTags(_ tags: Set<String>, for repo: RepositoryStore) {
        let path = repo.url.standardizedFileURL.path
        file.setTags(Array(tags), for: path)
        fileDidChange()
        repo.applyPrefs(prefs(for: path))
        if case .tag(let tag) = scope, !allTags.contains(tag) { scope = .all }
    }

    /// A global pref change, pushed straight into `repo` (other windows get it via `app`).
    public func setSharedPref(for repo: RepositoryStore, _ change: (inout RepoPrefs) -> Void) {
        app.updatePrefs(for: repo.url.path, change)
        repo.applyPrefs(prefs(for: repo.url.standardizedFileURL.path))
    }

    public func setLocalAIOnly(_ value: Bool, for repo: RepositoryStore) { setSharedPref(for: repo) { $0.localAIOnly = value } }
    /// `nil` falls back to the global `AppSettings.agentProfile`.
    public func setAgentPatterns(_ patterns: [String]?, for repo: RepositoryStore) { setSharedPref(for: repo) { $0.agentPatterns = patterns } }
    public func setFetchCadence(_ cadence: FetchCadence, for repo: RepositoryStore) { setSharedPref(for: repo) { $0.fetchCadence = cadence } }
    public func setSecretScanIgnoredPaths(_ paths: [String], for repo: RepositoryStore) {
        setSharedPref(for: repo) { $0.secretScanIgnoredPaths = paths.sorted() }
    }
    /// "Don't Check Selected Again" in the push secrets sheet: these files skip every secret scan.
    public func ignoreSecretScan(_ paths: [String], for repo: RepositoryStore) {
        setSharedPref(for: repo) { $0.secretScanIgnoredPaths = Array(Set($0.secretScanIgnoredPaths).union(paths)).sorted() }
    }
    /// `nil` clears it (fetch/push fall back to upstream / "origin").
    public func setDefaultRemote(_ remote: String?, for repo: RepositoryStore) { setSharedPref(for: repo) { $0.defaultRemote = remote } }

    public func setSelectedPath(_ path: String?, for repo: RepositoryStore) {
        app.updatePrefs(for: repo.url.path) { $0.selectedPath = path }
        // In memory too (same as `setCommitDraft`), so selecting the repo afterwards lands on
        // `path` — how workspace search opens a hit in another repository.
        repo.restoredSelectedPath = path
    }

    /// Persists the user's chosen Compare base branch (T4) — same shape as `setSelectedPath`.
    public func setCompareBase(_ base: String?, for repo: RepositoryStore) {
        app.updatePrefs(for: repo.url.path) { $0.compareBase = base }
        repo.restoredCompareBase = base
    }

    /// Debounced 1s (by default) so typing a commit message doesn't rewrite `workspace.json` on
    /// every keystroke (one `Debouncer` per repo). `repo.restoredDraft` is updated right away (C4):
    /// it's the in-memory hint the view re-reads when a tab/repo is reselected, so it must reflect
    /// the latest typed draft even before the debounced write to disk has fired.
    public func setCommitDraft(_ draft: CommitMessage?, for repo: RepositoryStore) {
        repo.restoredDraft = draft
        let saver = draftSavers[repo.url] ?? Debouncer()
        draftSavers[repo.url] = saver
        let path = repo.url.path
        saver.schedule(draftDebounce) { [weak self] in self?.writeCommitDraft(draft, path: path) }
    }

    /// Writes out any debounced draft that hasn't landed yet, so closing the workspace can't
    /// silently drop a half-typed commit message.
    func flushPendingDraftWrites() {
        draftSavers.values.forEach { $0.flush() }
        draftSavers = [:]
    }

    private func writeCommitDraft(_ draft: CommitMessage?, path: String) {
        app.updatePrefs(for: path) { $0.commitDraft = (draft?.isEmpty == false) ? draft : nil }
    }

    public func updateSettings(_ settings: AppSettings) { app.updateSettings(settings) }

    /// Called by `app` after any window changed `path`'s global prefs.
    /// Persists the activity time (rare: only real changes), and keeps the selected repo "seen".
    private func fingerprintDidChange(_ store: RepositoryStore) {
        if let activity = store.lastActivity, activity != app.prefs(for: store.url.path).lastActivity {
            app.updatePrefs(for: store.url.path) { $0.lastActivity = activity }
        }
        if store.id == selectedRepoID { markViewed(store) }
    }

    /// Records `store`'s current state as seen. `updatePrefs` writes synchronously, hence the `!=` guard.
    private func markViewed(_ store: RepositoryStore) {
        guard let fingerprint = store.fingerprint,
              app.prefs(for: store.url.path).lastViewedFingerprint != fingerprint else { return }
        store.lastViewedFingerprint = fingerprint
        app.updatePrefs(for: store.url.path) { $0.lastViewedFingerprint = fingerprint }
    }

    func sharedPrefsDidChange(for path: String, _ prefs: RepoPrefs) {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        for repo in repositories where repo.url.standardizedFileURL.path == target { repo.applySharedPrefs(prefs) }
    }

    /// Called by `app` after any settings change: restarts auto-fetch with the new interval.
    public func settingsDidChange() {
        startAutoFetch()
        repositories.forEach(syncActivityTracking)
    }

    /// Mirrors `trackRemoteActivity` onto `store`; turning it on takes the baseline snapshot (local
    /// refs only, no network) so the next fetch already reports what changed. Also mirrors the
    /// global `agentProfile`.
    private func syncActivityTracking(_ store: RepositoryStore) {
        if store.globalAgentProfile != app.settings.agentProfile { store.globalAgentProfile = app.settings.agentProfile }
        store.tracksRemoteActivity = app.settings.trackRemoteActivity
        guard store.tracksRemoteActivity else { store.remoteSnapshot = nil; return }
        Task { [weak store] in await store?.takeInitialRemoteSnapshot() }
    }
}
