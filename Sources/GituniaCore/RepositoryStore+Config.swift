import Foundation

/// A config key's effective value in this repository and the scope it comes from.
public struct ConfigValue: Sendable, Equatable {
    public enum Scope: String, Sendable {
        case local, global, system, worktree, unset
    }

    public var key: String
    public var value: String?
    public var scope: Scope
    /// What the key would be without the local/worktree setting (global, else system) — shown as
    /// the "Inherited (…)" option and text placeholder.
    public var inherited: String?

    public init(key: String, value: String?, scope: Scope, inherited: String? = nil) {
        self.key = key
        self.value = value
        self.scope = scope
        self.inherited = inherited
    }
}

/// One line of `git config --list --show-scope --show-origin`.
public struct ConfigEntry: Sendable, Equatable {
    public var scope: ConfigValue.Scope
    public var origin: String
    public var key: String
    public var value: String
}

extension RepositoryStore {
    /// One `git config --list --show-scope --show-origin` call, resolved per requested key.
    public func configValues(for keys: [String]) async -> [ConfigValue] {
        let out = (try? await git.run(["config", "--list", "--show-scope", "--show-origin"], in: url)) ?? ""
        return Self.resolve(Self.parseConfigList(out), keys: keys)
    }

    /// `git config [--global] <key> <value>`, or `--unset-all` when `value` is nil (exit 5 = wasn't set).
    /// Only `.global` writes globally; any other scope writes to the repository.
    public func setConfig(_ key: String, value: String?, scope: ConfigValue.Scope) async -> GitError? {
        let args = ["config"] + (scope == .global ? ["--global"] : []) + (value.map { [key, $0] } ?? ["--unset-all", key])
        return await attempt(args, allowedExitCodes: value == nil ? [0, 5] : [0])
    }

    /// `<scope>\t<origin>\t<key>=<value>` per line. `command` scope is skipped — those are the
    /// runner's own `-c` hardening flags, not the user's config. `unknown` (e.g. Xcode's bundled
    /// gitconfig) counts as system. A bare key (`[commit] gpgsign`) means `true`.
    public nonisolated static func parseConfigList(_ output: String) -> [ConfigEntry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let scope: ConfigValue.Scope
            switch fields[0] {
            case "local": scope = .local
            case "global": scope = .global
            case "worktree": scope = .worktree
            case "system", "unknown": scope = .system
            default: return nil
            }
            let kv = fields[2].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return ConfigEntry(scope: scope, origin: String(fields[1]), key: String(kv[0]),
                               value: kv.count > 1 ? String(kv[1]) : "true")
        }
    }

    /// git lists scopes system → global → local → worktree, so the last occurrence of a key is the
    /// effective one; `inherited` is the last one outside local/worktree. Keys compare
    /// case-insensitively (git lowercases section and name).
    public nonisolated static func resolve(_ entries: [ConfigEntry], keys: [String]) -> [ConfigValue] {
        keys.map { key in
            let matches = entries.filter { $0.key.lowercased() == key.lowercased() }
            let inherited = matches.last { $0.scope == .global || $0.scope == .system }?.value
            guard let last = matches.last else { return ConfigValue(key: key, value: nil, scope: .unset) }
            return ConfigValue(key: key, value: last.value, scope: last.scope, inherited: inherited)
        }
    }
}
