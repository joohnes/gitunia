import Foundation

/// Where a repository's hooks directory came from.
public enum HookSource: Hashable, Sendable {
    /// `<common gitdir>/hooks` — no `core.hooksPath` set.
    case repo
    /// `core.hooksPath` from the repo's own (local/worktree) config, as written.
    case hooksPath(String)
    /// `core.hooksPath` from global/system config — applies to every repo on this machine.
    case globalHooksPath
}

/// One file in the hooks directory. Git only runs a hook that is executable and not `*.sample`.
public struct GitHook: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: URL
    public let isExecutable: Bool
    public let isSample: Bool
    public let source: HookSource
    /// First line (usually the shebang), trimmed; `nil` for an empty/unreadable file.
    public let firstLine: String?
    public var id: String { path.path }
    /// Git would run it.
    public var isActive: Bool { isExecutable && !isSample }

    public init(name: String, path: URL, isExecutable: Bool, isSample: Bool, source: HookSource, firstLine: String?) {
        self.name = name; self.path = path; self.isExecutable = isExecutable
        self.isSample = isSample; self.source = source; self.firstLine = firstLine
    }
}

/// Hooks: visible, not secret — an agent that installs a hook is something the supervisor must see.
extension RepositoryStore {
    /// Hooks `hooks()` last found that git would actually run.
    public var activeHookCount: Int { gitHooks.filter(\.isActive).count }
    public var hasActiveHooks: Bool { activeHookCount > 0 }

    /// `core.hooksPath` (relative = relative to the repo root, `~` expanded) or else
    /// `<git-common-dir>/hooks` — a linked worktree shares the main repo's hooks.
    public func hooksDirectory() async -> (url: URL, source: HookSource)? {
        let configured = (try? await git.run(["config", "--show-scope", "--get", "core.hooksPath"], in: url, allowedExitCodes: [0, 1])) ?? ""
        let line = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tab = line.firstIndex(of: "\t") {
            let scope = line[..<tab]
            let raw = String(line[line.index(after: tab)...])
            let expanded = (raw as NSString).expandingTildeInPath
            let dir = resolve(expanded)
            return (dir, scope == "global" || scope == "system" ? .globalHooksPath : .hooksPath(raw))
        }
        let common = (try? await git.run(["rev-parse", "--git-common-dir"], in: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gitDir = common.flatMap({ $0.isEmpty ? nil : resolve($0) }) ?? gitDirURL() else { return nil }
        return (gitDir.appendingPathComponent("hooks"), .repo)
    }

    /// Absolute as-is, else relative to the repo root (`relativeTo:` would drop `url`'s last
    /// component when it lacks a trailing slash).
    private func resolve(_ path: String) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)).standardizedFileURL
    }

    /// Every regular file in the hooks directory, by name. Also refreshes `gitHooks`.
    @discardableResult
    public func hooks() async -> [GitHook] {
        guard let (dir, source) = await hooksDirectory() else { gitHooks = []; return [] }
        let found = await Task.detached { Self.listHooks(in: dir, source: source) }.value
        gitHooks = found
        return found
    }

    /// Up to 64 KB of the hook, UTF-8 lossy.
    public func hookContents(_ hook: GitHook) async -> String? {
        await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: hook.path) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// Toggles the executable bits (git skips non-executable hooks) — never deletes. Refreshes `gitHooks`.
    public func setHookEnabled(_ hook: GitHook, _ enabled: Bool) async -> Error? {
        let error: Error? = await Task.detached {
            do {
                let fm = FileManager.default
                let perms = (try fm.attributesOfItem(atPath: hook.path.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
                let updated = enabled ? perms | 0o111 : perms & ~0o111
                try fm.setAttributes([.posixPermissions: NSNumber(value: updated)], ofItemAtPath: hook.path.path)
                return nil
            } catch {
                return error
            }
        }.value
        await hooks()
        return error
    }

    nonisolated private static func listHooks(in dir: URL, source: HookSource) -> [GitHook] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name in
            let path = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard !name.hasPrefix("."), fm.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return GitHook(name: name, path: path, isExecutable: fm.isExecutableFile(atPath: path.path),
                           isSample: name.hasSuffix(".sample"), source: source, firstLine: firstLine(of: path))
        }
    }

    nonisolated private static func firstLine(of path: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }
}
