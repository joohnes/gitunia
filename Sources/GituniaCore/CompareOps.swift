import Foundation

/// Ahead/behind counts for a base/head pair — `ahead` is commits on `head` not on `base`,
/// `behind` is commits on `base` not on `head`. Parses `git rev-list --left-right --count
/// base...head`, whose output is `<base-only>\t<head-only>` (left side first).
public struct CompareCounts: Equatable, Sendable {
    public let ahead: Int
    public let behind: Int
    public init(ahead: Int, behind: Int) {
        self.ahead = ahead; self.behind = behind
    }

    public static func parse(_ text: String) -> CompareCounts {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        let behind = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
        let ahead = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return CompareCounts(ahead: ahead, behind: behind)
    }
}

/// The repository's base branch — the one resolver behind both the Compare tab's default base and
/// Delete Merged Branches (via `RepositoryStore.baseBranch()`, which prefers the user's persisted
/// Compare choice). Pure — no git call itself, so it's testable without a repo
/// (`RepositoryStore.defaultBaseBranch()` gathers the inputs). Order: the remote's default branch
/// (`origin/HEAD`'s target) — as the local branch of that name when one exists, else as
/// `origin/<name>` so it's always a ref that resolves — then local `master`, then local `main`,
/// else `nil` (the UI then asks the user to pick one).
public enum CompareBase {
    public static func resolve(originHEADRef: String?, localBranches: [String]) -> String? {
        if let originHEADRef, let name = parseSymbolicRef(originHEADRef) {
            return localBranches.contains(name) ? name : "origin/\(name)"
        }
        if localBranches.contains("master") { return "master" }
        if localBranches.contains("main") { return "main" }
        return nil
    }

    /// `git symbolic-ref refs/remotes/origin/HEAD` prints `refs/remotes/origin/<branch>` on
    /// success, or (when unset) exits 128 with nothing on stdout — the caller passes that empty/
    /// failed output straight through as `nil`.
    private static func parseSymbolicRef(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "refs/remotes/origin/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let name = trimmed.dropFirst(prefix.count)
        return name.isEmpty ? nil : String(name)
    }
}

/// Which local branches Delete Merged Branches offers.
public enum MergedCleanup {
    /// `merged` is `for-each-ref --merged <base> refs/heads` (local names). Drops the current
    /// branch and the base's local counterpart: `base` itself when it's local (a branch is always
    /// merged into itself, so it's in `merged`), else `origin/main` → `main`.
    public static func candidates(merged: [String], base: String, current: String?) -> [String] {
        let baseLocal = merged.contains(base) ? base : (base.split(separator: "/", maxSplits: 1).last.map(String.init) ?? base)
        return merged.filter { $0 != current && $0 != baseLocal }
    }
}
