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
        pendingRescan.values.forEach { $0.cancel() }
        pendingRescan = [:]
        flushPendingDraftWrites()
        flushSave()
        stopAutoFetch()
    }

    private func handleChanges(_ paths: [String]) {
        let roots = repositories.map(\.url)
        // A linked worktree's HEAD/index/refs live under the *main* repo's
        // `.git/worktrees/<name>/`, not under the worktree's own root (H2) — resolve each repo's
        // real gitdir so such a path routes to the worktree's own `RepositoryStore` instead of
        // being attributed to the main repo purely because its root path prefix-matches.
        var gitDirs: [URL: URL] = [:]
        for repo in repositories {
            if let gitDir = repo.gitDirURL() { gitDirs[repo.url] = gitDir }
        }
        var unowned: [String] = []
        var touched = Set<URL>()
        for path in paths {
            if let root = WorkspaceStore.repository(owning: path, among: roots, gitDirs: gitDirs) { touched.insert(root) }
            else { unowned.append(path) }
        }
        for root in touched {
            pendingRefresh[root]?.cancel()
            // A repo with thousands of changes is usually mid mass-rewrite (an agent, a codegen
            // run): each refresh costs a big `git status` plus re-rendering the list, so wait for
            // a longer quiet period before paying it again.
            let manyChanges = (repositories.first { $0.url == root }?.repo.changes.count ?? 0) > 1000
            pendingRefresh[root] = Task { [weak self] in
                try? await Task.sleep(for: manyChanges ? .seconds(1) : .milliseconds(300))
                guard !Task.isCancelled, let self, let repo = self.repositories.first(where: { $0.url == root }) else { return }
                await repo.refreshStatus()
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

    /// Drops noise inside `.git/`: only HEAD, index and refs/ matter. A linked worktree's own
    /// HEAD/index/refs live one level deeper, under `.git/worktrees/<name>/` in the *main* repo's
    /// git directory (H2) — that shape is accepted too, so a commit/checkout made inside a worktree
    /// still triggers a refresh instead of being dropped as noise.
    public nonisolated static func relevantPaths(_ paths: [String]) -> [String] {
        paths.filter { p in
            guard let r = p.range(of: "/.git/") else { return true }
            var inner = Substring(p[r.upperBound...])
            if inner.hasPrefix("worktrees/") {
                // Drop the "worktrees/<name>/" prefix and test what's left the same way.
                guard let nameEnd = inner.dropFirst("worktrees/".count).firstIndex(of: "/") else { return false }
                inner = inner[inner.index(after: nameEnd)...]
            }
            return inner == "HEAD" || inner == "index" || inner.hasPrefix("refs/")
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
