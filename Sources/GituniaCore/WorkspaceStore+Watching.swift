import Foundation

extension WorkspaceStore {
    // MARK: - Watching

    /// One stream over every linked folder and single repo.
    func startWatching() {
        let paths = file.folders.map(\.path) + file.repositories
        guard !paths.isEmpty else { return }
        let watcher = FSEventsWatcher(paths: paths) { [weak self] paths in
            let relevant = WorkspaceStore.relevantPaths(paths)
            guard !relevant.isEmpty else { return }
            Task { @MainActor [weak self] in self?.handleChanges(relevant) }
        }
        watcher.start()
        self.watcher = watcher
    }

    func restartWatching() {
        watcher?.stop()
        watcher = nil
        startWatching()
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        pendingRefresh.values.forEach { $0.cancel() }
        pendingRefresh = [:]
        pendingRefreshSince = [:]
        pendingRescan.values.forEach { $0.cancel() }
        pendingRescan = [:]
        flushPendingDraftWrites()
        flushSave()
        app.flushPendingWrites()
        stopAutoFetch()
    }

    private func handleChanges(_ paths: [String]) {
        // A linked worktree's HEAD/index/refs live under the *main* repo's
        // `.git/worktrees/<name>/`, not under the worktree's own root (H2) — resolve each repo's
        // real gitdir so such a path routes to the worktree's own `RepositoryStore` instead of
        // being attributed to the main repo purely because its root path prefix-matches.
        // Prefixes are built once per batch, longest first, so routing a big batch (an `npm install`)
        // is one prefix test per candidate rather than re-deriving every repo's path per event path.
        let byRoot = Dictionary(repositories.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let gitDirPrefixes = repositories.compactMap { repo in repo.gitDirURL().map { (root: repo.url, path: $0.path) } }
            .sorted { $0.path.utf8.count > $1.path.utf8.count }
        let rootPrefixes = repositories.map { (root: $0.url, path: $0.url.path) }
            .sorted { $0.path.utf8.count > $1.path.utf8.count }
        func owner(_ path: String) -> URL? {
            func under(_ prefix: String) -> Bool {
                path.hasPrefix(prefix) && (path.utf8.count == prefix.utf8.count
                    || path.utf8.dropFirst(prefix.utf8.count).first == UInt8(ascii: "/"))
            }
            return gitDirPrefixes.first { under($0.path) }?.root ?? rootPrefixes.first { under($0.path) }?.root
        }
        var unowned: [String] = []
        var touched = Set<URL>()
        var touchedGitDir = Set<URL>()
        for path in paths {
            if let root = owner(path) {
                touched.insert(root)
                if path.contains("/.git/") { touchedGitDir.insert(root) }
            } else {
                unowned.append(path)
            }
        }
        let now = ContinuousClock.now
        for root in touched {
            // Only a batch that touched HEAD/index/refs can have moved branches; a working-tree-only
            // batch lets the refresh skip `for-each-ref`. Marked now, not when the debounce fires,
            // so a later working-tree-only batch that replaces this pending refresh can't lose it.
            if touchedGitDir.contains(root), let repo = byRoot[root] { repo.statusRefreshNeedsRefs = true }
            // Debounced, but with a ceiling: under steady writes (an agent, a watch build) a plain
            // "quiet for 300ms" debounce would never fire. Past `maxRefreshDelay` the pending
            // refresh is left to fire instead of being pushed back again.
            if pendingRefresh[root] != nil, let since = pendingRefreshSince[root], now - since >= Self.maxRefreshDelay { continue }
            pendingRefresh[root]?.cancel()
            if pendingRefreshSince[root] == nil { pendingRefreshSince[root] = now }
            // A repo with thousands of changes is usually mid mass-rewrite (an agent, a codegen
            // run): each refresh costs a big `git status` plus re-rendering the list, so wait for
            // a longer quiet period before paying it again.
            let manyChanges = (byRoot[root]?.repo.changes.count ?? 0) > 1000
            pendingRefresh[root] = Task { [weak self] in
                try? await Task.sleep(for: manyChanges ? .seconds(1) : .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.pendingRefresh[root] = nil
                self.pendingRefreshSince[root] = nil
                guard let repo = self.repositories.first(where: { $0.url == root }) else { return }
                await repo.refreshStatus(refs: false)
            }
        }
        // A change nobody owns inside a linked folder may be a new repo (an agent's fresh worktree
        // or clone) — rescan just that folder.
        for folder in file.folders.map(\.path) where unowned.contains(where: { $0.hasPrefix(folder + "/") }) {
            pendingRescan[folder]?.cancel()
            pendingRescan[folder] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.rescan(folder: folder)
            }
        }
    }

    /// Rescans the linked folder containing `url` (no-op if none) — e.g. right after a worktree
    /// add/remove, instead of waiting for FSEvents.
    public func rescanFolder(containing url: URL) async {
        let target = url.resolvingSymlinksInPath().path + "/"
        for folder in file.folders.map(\.path) where target.hasPrefix(URL(fileURLWithPath: folder).resolvingSymlinksInPath().path + "/") {
            await rescan(folder: folder)
        }
    }

    public func rescan(folder: String) async {
        // `refreshAll` is already rebuilding membership from a fresh scan of every folder — running
        // this one concurrently would race `applyMembership` (A3) and could construct a duplicate
        // `RepositoryStore` for a repo `refreshAll`'s own scan is about to add. Bail out; `refreshAll`
        // covers this folder too.
        guard !isScanning else { return }
        let found = await Task.detached {
            WorkspaceScanner.findRepositories(in: URL(fileURLWithPath: folder)).map { $0.standardizedFileURL.path }
        }.value
        guard found != folderScans[folder] else { return }
        let before = Set(repositories.map(\.id))
        folderScans[folder] = found
        applyMembership()
        let joined = repositories.filter { !before.contains($0.id) }
        for repo in joined {
            await repo.refreshStatus()
            onRepoEvents?(repo, [.repositoryJoined])
        }
        persistUnseenBaselines(for: joined)
    }

    /// Longest a burst of file events can keep pushing a repository's refresh back.
    static let maxRefreshDelay: Duration = .seconds(2)

    /// Build-output and dependency folders that are gitignored in practice: a watch build or an
    /// `npm install` writes thousands of files there, and each burst would otherwise cost a full
    /// `git status` that reports nothing new. ponytail: a repo that *tracks* one of these (vendored
    /// `node_modules`) sees edits there on its next other refresh, not immediately.
    nonisolated static let ignoredDirectories = [
        "/node_modules/", "/.build/", "/DerivedData/", "/__pycache__/", "/.gradle/", "/.next/", "/.nuxt/",
        "/.turbo/", "/.parcel-cache/", "/.pytest_cache/", "/.mypy_cache/", "/.ruff_cache/", "/.tox/", "/.venv/",
    ]

    /// Drops noise inside `.git/`: only HEAD, index, refs/ and packed-refs matter (a deleted or
    /// renamed packed branch only rewrites `packed-refs`). A linked worktree's own HEAD/index/refs
    /// live one level deeper, under `.git/worktrees/<name>/` in the *main* repo's git directory
    /// (H2) — that shape is accepted too, so a commit/checkout made inside a worktree still
    /// triggers a refresh instead of being dropped as noise. Paths under `ignoredDirectories` go too.
    public nonisolated static func relevantPaths(_ paths: [String]) -> [String] {
        paths.filter { p in
            guard let r = p.range(of: "/.git/") else {
                return !ignoredDirectories.contains { p.contains($0) }
            }
            var inner = Substring(p[r.upperBound...])
            if inner.hasPrefix("worktrees/") {
                // Drop the "worktrees/<name>/" prefix and test what's left the same way.
                guard let nameEnd = inner.dropFirst("worktrees/".count).firstIndex(of: "/") else { return false }
                inner = inner[inner.index(after: nameEnd)...]
            }
            return inner == "HEAD" || inner == "index" || inner == "packed-refs" || inner.hasPrefix("refs/")
        }
    }

    /// Longest root that is a path-prefix of `path` — or, if `path` instead falls under a repo's
    /// resolved git directory (`gitDirs`), that repo's root (H2). The latter is what routes a
    /// linked worktree's `HEAD`/`index`/`refs` change — physically stored under the main repo's
    /// `.git/worktrees/<name>/` — to the worktree's own `RepositoryStore` rather than the main
    /// repo's, whose working-tree root would otherwise be the only (and wrong) prefix match.
    /// `gitDirs` is empty by default so callers that don't know about worktrees keep the old,
    /// root-only behavior.
    public nonisolated static func repository(owning path: String, among roots: [URL], gitDirs: [URL: URL] = [:]) -> URL? {
        if let match = gitDirs
            .filter({ _, gitDir in path == gitDir.path || path.hasPrefix(gitDir.path + "/") })
            .max(by: { $0.value.path.count < $1.value.path.count }) {
            return match.key
        }
        return roots
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}
