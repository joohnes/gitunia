import Foundation
import Observation

/// The global `workspace.json`, shared by every window: app settings, per-repo prefs that follow
/// a repo into any workspace, the open windows and recent workspaces. One instance per app, so two
/// windows can never overwrite each other's changes with a stale copy.
@MainActor
@Observable
public final class AppConfig {
    public private(set) var config: WorkspaceConfig
    public private(set) var loadWarning: String?
    /// Set when saving `workspace.json` fails, for the UI to toast and then `dismissPersistError()`.
    /// Every later save hits the same failure, so the same message is reported once until a save
    /// succeeds again — otherwise each settings or selection change would stack another toast.
    public private(set) var persistError: String?
    @ObservationIgnored private var reportedPersistError: String?
    public let configStore: ConfigStore
    /// Remote activity log, `activity.json` next to `workspace.json`.
    public let activity: ActivityLog
    @ObservationIgnored private var attached: [WeakStore] = []

    private struct WeakStore { weak var store: WorkspaceStore? }

    public init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        // Only for the real location: tests inject temp stores and must never touch the user's files.
        let isDefaultLocation = configStore.fileURL == ConfigStore.defaultFileURL
        // A4: `defaultFileURL` already resolved to Application Support if Documents was denied by
        // TCC — migrating legacy files *into* Documents would be pointless (and would just fail
        // again) in that case, so only attempt it when Documents is where we're actually writing.
        let usingFallback = isDefaultLocation
            && configStore.fileURL.deletingLastPathComponent().standardizedFileURL == AppDataLocation.legacyDirectory.standardizedFileURL
        var moveError: String?
        if isDefaultLocation && !usingFallback {
            moveError = AppDataLocation.migrateIfNeeded().error
            // Settings → Storage picked a new folder last session: bring the old folder's files over.
            if let previous = AppDataLocation.takePendingMove() {
                moveError = AppDataLocation.migrateIfNeeded(from: previous, to: AppDataLocation.directory).error ?? moveError
            }
        }
        let (cfg, warning) = configStore.loadWithWarning()
        config = cfg
        if let warning {
            loadWarning = warning
        } else if let moveError {
            loadWarning = "Couldn't move Gitunia's files to \(AppDataLocation.directory.path): \(moveError)"
        } else if usingFallback {
            loadWarning = "Gitunia couldn't write to \(AppDataLocation.directory.path) (permission denied) and is using Application Support instead. Allow access in System Settings → Privacy & Security → Files and Folders, then use Retry in Settings → Storage."
        } else {
            loadWarning = nil
        }
        activity = ActivityLog(fileURL: configStore.fileURL.deletingLastPathComponent().appendingPathComponent("activity.json"))
        activity.prune(olderThan: cfg.settings.activityRetentionDays)
        // B11: only for the real app, same as the migration above — a test's temp `$TMPDIR` isn't
        // ours to sweep, and tests reusing that guard keeps this out of their way.
        if isDefaultLocation { AppDataLocation.cleanupTemp(prefix: "", olderThan: 24 * 60 * 60, in: AppDataLocation.rebaseTempDirectory) }
        // File-preview cache (`RepositoryStore.previewFile`): whole folder, not date-gated — it's
        // pure cache, cheap to regenerate, and this way there's no partial-content edge case.
        if isDefaultLocation { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-preview", isDirectory: true)) }
    }

    /// Settings → Storage "Retry Documents": re-probes Documents, migrates over anything still in
    /// Application Support, and reports whether `AppConfig` could re-point itself live or the app
    /// needs a restart to pick up the new location (its `configStore.fileURL` is `let`).
    public func retryDocumentsAccess() -> RetryResult {
        guard AppDataLocation.writableDirectory() == AppDataLocation.directory else { return .stillDenied }
        AppDataLocation.migrateIfNeeded()
        return configStore.fileURL.deletingLastPathComponent().standardizedFileURL == AppDataLocation.directory.standardizedFileURL
            ? .movedLive
            : .needsRestart
    }

    public enum RetryResult: Sendable { case movedLive, needsRestart, stillDenied }

    public var untitledDirectory: URL {
        configStore.fileURL.deletingLastPathComponent().appendingPathComponent("Untitled", isDirectory: true)
    }

    public var settings: AppSettings { config.settings }

    public func updateSettings(_ settings: AppSettings) {
        config.settings = settings
        persist()
        attached.removeAll { $0.store == nil }
        attached.forEach { $0.store?.settingsDidChange() }
    }

    public func prefs(for path: String) -> RepoPrefs { config.repos[path] ?? RepoPrefs() }

    public func updatePrefs(for path: String, _ change: (inout RepoPrefs) -> Void) {
        var prefs = prefs(for: path)
        change(&prefs)
        config.repos[path] = prefs
        persist()
        // Local AI only is a privacy guard read from each window's own `RepositoryStore`, so every
        // window showing this repo must see the change, not just the one that made it.
        attached.removeAll { $0.store == nil }
        attached.forEach { $0.store?.sharedPrefsDidChange(for: path, prefs) }
    }

    /// Same as `updatePrefs(for:_:)` but for several repos at once, with a single `persist()` (A5):
    /// e.g. `WorkspaceStore.refreshAll` seeding the "unseen changes" baseline for every repo it just
    /// loaded shouldn't rewrite `workspace.json` once per repo.
    public func updatePrefs(batch: [(path: String, change: (inout RepoPrefs) -> Void)]) {
        guard !batch.isEmpty else { return }
        var updated: [(path: String, prefs: RepoPrefs)] = []
        for (path, change) in batch {
            var prefs = prefs(for: path)
            change(&prefs)
            config.repos[path] = prefs
            updated.append((path, prefs))
        }
        persist()
        // Local AI only is a privacy guard read from each window's own `RepositoryStore`, so every
        // window showing this repo must see the change, not just the one that made it.
        attached.removeAll { $0.store == nil }
        for (path, prefs) in updated {
            attached.forEach { $0.store?.sharedPrefsDidChange(for: path, prefs) }
        }
    }

    public func setWindows(_ windows: [WindowState]) {
        guard windows != config.windows else { return }
        config.windows = windows
        persist()
    }

    /// Save As moved a window's workspace: point the saved window list at the new file right away,
    /// since the old (untitled) file is about to be deleted.
    func workspaceMoved(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        setWindows(config.windows.map { w in
            guard URL(fileURLWithPath: w.workspace).standardizedFileURL.path == oldPath else { return w }
            var moved = w
            moved.workspace = new.standardizedFileURL.path
            return moved
        })
    }

    public func noteRecent(_ fileURL: URL) {
        guard !isUntitled(fileURL) else { return }
        let path = fileURL.standardizedFileURL.path
        config.recentWorkspaces.removeAll { $0 == path }
        config.recentWorkspaces.insert(path, at: 0)
        if config.recentWorkspaces.count > 10 { config.recentWorkspaces.removeLast(config.recentWorkspaces.count - 10) }
        persist()
    }

    public func clearRecents() {
        config.recentWorkspaces = []
        persist()
    }

    public func setLastRepoParent(_ url: URL) {
        config.lastRepoParent = url.standardizedFileURL.path
        persist()
    }

    public func dismissLoadWarning() { loadWarning = nil }

    /// `UpdateCoordinator` just ran a check (due or forced) — stamps the 24h throttle.
    public func noteUpdateCheck() {
        config.updateState.lastCheck = Date()
        persist()
    }

    /// Settings → Updates "Skip this version": no more toasts for that release.
    public func skipUpdate(version: String) {
        config.updateState.skippedVersion = version
        persist()
    }

    public func newUntitledURL() -> URL {
        untitledDirectory.appendingPathComponent("\(UUID().uuidString).\(WorkspaceFile.fileExtension)")
    }

    public func isUntitled(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == untitledDirectory.standardizedFileURL.path
    }

    @discardableResult
    public func migrateIfNeeded() -> URL? {
        guard let (migrated, file) = WorkspaceMigration.migrate(config) else { return nil }
        let url = newUntitledURL()
        do { try file.save(to: url, relativePaths: false) } catch {
            // `workspacePath` stays, so the next launch tries again.
            loadWarning = "Couldn't move your workspace folder \(file.folders.first?.path ?? "") into a workspace file (\(error.localizedDescription)). Gitunia will try again next launch."
            return nil
        }
        config = migrated
        // Appended: a launch after a failed attempt may already have saved windows.
        config.windows.append(WindowState(workspace: url.path))
        persist()
        return url
    }

    func attach(_ store: WorkspaceStore) {
        attached.removeAll { $0.store == nil || $0.store === store }
        attached.append(WeakStore(store: store))
    }

    public func dismissPersistError() { persistError = nil }

    private func persist() {
        do {
            try configStore.save(config)
            reportedPersistError = nil
        } catch {
            let message = "\(configStore.fileURL.path): \(error.localizedDescription)"
            guard message != reportedPersistError else { return }
            reportedPersistError = message
            persistError = message
        }
    }
}
