import Foundation

public struct BulkOperation: Sendable, Equatable {
    public struct Failure: Sendable, Equatable { public let repo: String; public let message: String }
    public let kind: RemoteKind
    public var completed: Int
    public var total: Int
    public var failures: [Failure]
}

extension WorkspaceStore {
    // MARK: - Bulk operations

    /// Runs `action` over every repository in `repositories` (not just `visibleRepositories` — a tag
    /// filter is a view concern, not a scope for a bulk action; revisit if that reads wrong from the UI).
    /// Same bounded-concurrency shape as `refreshAll`: unstructured `Task {}` per repo, chunked by 8 —
    /// a `TaskGroup` whose child tasks call back into these `@MainActor` store methods hits the same
    /// compiler limitation documented there ("pattern that the region-based isolation checker does not
    /// understand how to check") — reproduced directly against this method before falling back, not
    /// just inferred from that comment. `completed`/`failures` are updated as each chunk member's task
    /// is awaited, in the chunk's (= sidebar) order, so failures land in a stable order without a
    /// separate sort. `internal` rather than `private` so tests can inject a fake `action` (e.g. a
    /// slow one, to check the chunking actually overlaps instead of just timing `fetchAll`).
    func runBulk(
        _ kind: RemoteKind,
        silent: Bool,
        skip: (RepositoryStore) -> Bool,
        action: @escaping (RepositoryStore) async -> RemoteResult
    ) async -> BulkOperation {
        if let bulk { return bulk }
        guard !bulkInFlight else { return BulkOperation(kind: kind, completed: 0, total: 0, failures: []) }
        bulkInFlight = true
        defer { bulkInFlight = false }
        let eligible = repositories.filter { $0.repo.isAvailable && !skip($0) }
        var op = BulkOperation(kind: kind, completed: 0, total: eligible.count, failures: [])
        if !silent { bulk = op }
        for start in stride(from: 0, to: eligible.count, by: 8) {
            if Task.isCancelled { break }
            let chunk = eligible[start..<min(start + 8, eligible.count)]
            let tasks = chunk.map { repo in Task { (repo, await action(repo)) } }
            for task in tasks {
                let (repo, result) = await task.value
                op.completed += 1
                if !result.succeeded {
                    let stderr = result.error?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = (stderr?.isEmpty == false ? stderr : nil) ?? result.summary
                    op.failures.append(BulkOperation.Failure(repo: repo.repo.name, message: message))
                }
                if !silent { bulk = op }
            }
        }
        if !silent { bulk = nil }
        return op
    }

    /// `silent: true` (auto-fetch) runs the same work without ever publishing `bulk`, so no progress
    /// strip flashes on screen for a background tick — and goes through `autoFetch()`'s guard.
    @discardableResult
    public func fetchAll(silent: Bool = false, filter: (RepositoryStore) -> Bool = { _ in true }) async -> BulkOperation {
        await runBulk(.fetch, silent: silent, skip: { !filter($0) }) { silent ? await $0.autoFetch() : await $0.fetch() }
    }

    /// Repositories without an upstream are skipped (nothing to pull from, so not a failure).
    /// Diverged ones are counted but never pulled: `pull --ff-only` there is a dead end and resolving
    /// it (rebase vs. merge) is the user's choice, so they are reported as failures saying what to do.
    @discardableResult
    public func pullAll() async -> BulkOperation {
        await runBulk(.pull, silent: false, skip: { !$0.hasUpstream }) { repo in
            Preflight.isDiverged(repo: repo.repo)
                ? RemoteResult(kind: .pull, succeeded: false, summary: "Diverged — pull individually")
                : await repo.pull()
        }
    }

    /// Two skip rules, both shrinking `total` rather than counting as failures:
    /// - `hasUpstream && ahead == 0`: nothing to push, same reasoning as `pullAll`'s "nothing to
    ///   pull" skip.
    /// - no upstream at all: `RepositoryStore.push()` falls back to `push -u origin HEAD` for a
    ///   repo with no upstream, which *creates a remote branch*. That's a fine thing to do for one
    ///   repository you're looking at, but doing it silently across a whole workspace would publish
    ///   branches the user never explicitly asked to push. A first push is a decision, not
    ///   something a bulk sweep should make on your behalf — so those repos are skipped here, same
    ///   as the no-upstream skip in `pullAll`, and the caller's confirmation dialog only counts
    ///   repos that will actually be pushed.
    @discardableResult
    public func pushAll(excluding excluded: [RepositoryStore] = []) async -> BulkOperation {
        await runBulk(.push, silent: false, skip: { repo in !repo.hasUpstream || repo.repo.ahead == 0 || excluded.contains { $0 === repo } }) { await $0.push() }
    }

    /// `git stash push -u` in every changed repository. Clean repos and ones stopped mid-operation
    /// (a stash there would bury a half-done rebase/merge) are skipped, shrinking `total`.
    @discardableResult
    public func stashAll(message: String? = nil) async -> BulkOperation {
        await runBulk(.stash, silent: false, skip: Self.skipsStash) { repo in
            let ok = await repo.stash(message: message)
            return RemoteResult(kind: .stash, succeeded: ok, summary: ok ? "Stashed" : "Nothing to stash", error: repo.lastError)
        }
    }

    /// `stashAll`'s skip rule — public so the palette's confirmation lists exactly these repos.
    public static func skipsStash(_ repo: RepositoryStore) -> Bool { !repo.repo.hasChanges || repo.operation != nil }

    // MARK: - Auto-fetch

    /// Pure arithmetic so the interval is testable without sleeping in tests.
    public nonisolated static func autoFetchInterval(minutes: Int) -> Duration {
        .seconds(max(0, minutes) * 60)
    }

    /// Whether a repo with `cadence` is fetched on auto-fetch `tick`: the loop ticks five times per
    /// configured interval, so `normal` fires every 5th tick (the interval as set) and `intensive` on all.
    public nonisolated static func isFetchDue(cadence: FetchCadence, tick: Int) -> Bool {
        switch cadence {
        case .paused: false
        case .normal: tick % 5 == 0
        case .intensive: true
        }
    }

    func startAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = nil
        let minutes = app.settings.autoFetchMinutes
        guard minutes > 0, fileURL != nil else { return }
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                // A fifth of the interval (not whole minutes), so `normal` stays exact for 1–4 min settings.
                try? await Task.sleep(for: WorkspaceStore.autoFetchInterval(minutes: minutes) / 5)
                guard !Task.isCancelled, let self else { return }
                self.autoFetchTick += 1
                if !self.bulkInFlight {
                    let tick = self.autoFetchTick
                    _ = await self.fetchAll(silent: true) { WorkspaceStore.isFetchDue(cadence: $0.fetchCadence, tick: tick) }
                }
            }
        }
    }

    public func stopAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = nil
    }
}
