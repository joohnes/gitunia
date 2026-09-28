import Foundation

/// Where Gitunia keeps its own files: `~/Documents/Gitunia` unless the user picked another folder
/// in Settings → Storage (`workspace.json`, `activity.json`, `Untitled/`, any `.corrupt-*` backups),
/// visible so the user can find and back them up.
/// Older versions used `~/Library/Application Support/Gitunia`; `migrateIfNeeded` moves that over.
public enum AppDataLocation {
    /// The chosen folder lives in UserDefaults, not `workspace.json` — that file is inside it.
    static let customDirectoryKey = "GituniaDataDirectory"
    /// Folder whose files move into `directory` on the next launch (set by `choose`). Deferred to
    /// launch because the running app keeps writing to its current folder until it quits.
    static let pendingMoveKey = "GituniaDataDirectoryMoveFrom"

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitunia", isDirectory: true)
    }

    public static var directory: URL {
        UserDefaults.standard.string(forKey: customDirectoryKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
    }

    /// Settings → Storage "Change…": makes `newDir` the data folder from the next launch on, moving
    /// `current`'s files there then. Returns an error message when `newDir` can't be used.
    public static func choose(_ newDir: URL, current: URL) -> String? {
        let new = newDir.standardizedFileURL.path, cur = current.standardizedFileURL.path
        guard new != cur else { return nil }
        if new.hasPrefix(cur + "/") { return "Pick a folder outside the current one." }
        let defaults = UserDefaults.standard
        defaults.set(new, forKey: customDirectoryKey)
        defaults.set(cur, forKey: pendingMoveKey)
        return nil
    }

    /// Launch step for `choose`: moves the previous folder's files into `directory`, once.
    static func takePendingMove() -> URL? {
        let defaults = UserDefaults.standard
        guard let from = defaults.string(forKey: pendingMoveKey) else { return nil }
        defaults.removeObject(forKey: pendingMoveKey)
        return URL(fileURLWithPath: from, isDirectory: true)
    }

    public static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitunia", isDirectory: true)
    }

    /// `preferred` (`directory`) if Gitunia can actually create and write into it, else
    /// `fallback` (Application Support/Gitunia) — TCC can deny Documents access outright (A4), which
    /// would otherwise leave the app unable to persist `workspace.json` at all. Probes by creating
    /// the directory and writing+deleting a temp file, since `isWritableFile` doesn't see TCC denials.
    public static func writableDirectory(preferred: URL = directory, fallback: URL = legacyDirectory) -> URL {
        canWrite(to: preferred) ? preferred : fallback
    }

    private static func canWrite(to dir: URL) -> Bool {
        let fm = FileManager.default
        let probe = dir.appendingPathComponent(".gitunia-write-probe-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    public struct MigrationResult: Equatable, Sendable {
        public var moved: [String] = []
        public var skipped: [String] = []
        public var error: String?
    }

    static let noteName = "MIGRATED.txt"

    /// Moves everything from `legacy` into `target` unless `target` already has a `workspace.json`.
    /// Never overwrites a file already in `target` (those names land in `skipped`). Untitled
    /// workspace paths saved in the moved `workspace.json` are rewritten so they still restore.
    @discardableResult
    public static func migrateIfNeeded(from legacy: URL = legacyDirectory, to target: URL = directory) -> MigrationResult {
        let fm = FileManager.default
        var result = MigrationResult()
        guard !fm.fileExists(atPath: target.appendingPathComponent("workspace.json").path),
              fm.fileExists(atPath: legacy.path) else { return result }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: legacy.path) where name != noteName {
                let from = legacy.appendingPathComponent(name), to = target.appendingPathComponent(name)
                guard !fm.fileExists(atPath: to.path) else { result.skipped.append(name); continue }
                do { try fm.moveItem(at: from, to: to) } catch {
                    try fm.copyItem(at: from, to: to)
                    try fm.removeItem(at: from)
                }
                result.moved.append(name)
            }
        } catch {
            result.error = error.localizedDescription
        }
        if result.moved.contains("workspace.json") { rewriteUntitledPaths(in: target, legacy: legacy) }
        if !result.moved.isEmpty {
            try? "Gitunia's files moved to \(target.path)\n"
                .write(to: legacy.appendingPathComponent(noteName), atomically: true, encoding: .utf8)
        }
        return result
    }

    /// Tidy Commits' temp dirs live here, not loose in `$TMPDIR`: that can hold tens of thousands of
    /// entries (test runs), and listing it on launch blocked the main thread for seconds.
    public static var rebaseTempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-rebase", isDirectory: true)
    }

    /// Sweeps leftover Tidy Commits temp dirs (B11 — `RepositoryStore.interactiveRebase` never
    /// deletes its own, since a conflict-stopped rebase still needs the message files to continue
    /// later). Only removes ones older than `olderThan`, so an in-progress or just-stopped rebase is
    /// left alone; the OS would eventually reap `$TMPDIR` anyway, this just doesn't wait for a reboot.
    public static func cleanupTemp(prefix: String, olderThan: TimeInterval, in dir: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for name in names where name.hasPrefix(prefix) {
            let url = dir.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static func rewriteUntitledPaths(in target: URL, legacy: URL) {
        let store = ConfigStore(fileURL: target.appendingPathComponent("workspace.json"))
        // Raw decode, not `load()`: a corrupt file is left for `loadWithWarning` to report and back up.
        guard let data = try? Data(contentsOf: store.fileURL),
              var cfg = try? JSONDecoder().decode(WorkspaceConfig.self, from: data) else { return }
        let old = legacy.standardizedFileURL.path + "/Untitled/"
        let new = target.standardizedFileURL.path + "/Untitled/"
        func fix(_ path: String) -> String {
            path.hasPrefix(old) ? new + path.dropFirst(old.count) : path
        }
        let before = cfg
        cfg.windows = cfg.windows.map { var w = $0; w.workspace = fix(w.workspace); return w }
        cfg.recentWorkspaces = cfg.recentWorkspaces.map(fix)
        if cfg != before { try? store.save(cfg) }
    }
}
