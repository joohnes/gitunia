import Foundation

/// One side of a Compare: a ref (branch/commit), or a worktree of the same repository — its
/// working tree *including uncommitted and untracked changes*, which is what an agent's worktree
/// usually holds.
public enum CompareEndpoint: Hashable, Sendable {
    case ref(String)
    case worktree(path: URL, label: String)

    /// `CompareView`'s pickers keep their selection as a plain `String` (the lifted `ContentView`
    /// state and the persisted `compareBase` pref are branch names), so a worktree is tagged
    /// `worktree:<path>`. Unambiguous: `check-ref-format` forbids `:` in branch names.
    public static let selectionPrefix = "worktree:"

    public static func selection(for wt: Worktree) -> String { selectionPrefix + wt.path }

    /// "<folder name> · <branch>" (short HEAD when detached).
    public static func label(for wt: Worktree) -> String {
        let name = URL(fileURLWithPath: wt.path).lastPathComponent
        return "\(name) · \(wt.branch ?? String((wt.head ?? "detached").prefix(7)))"
    }

    /// Resolves a picker selection; an unknown worktree path still resolves (labelled by folder).
    public init(selection: String, worktrees: [Worktree]) {
        guard selection.hasPrefix(Self.selectionPrefix) else { self = .ref(selection); return }
        let path = String(selection.dropFirst(Self.selectionPrefix.count))
        let label = worktrees.first { $0.path == path }.map(Self.label(for:)) ?? URL(fileURLWithPath: path).lastPathComponent
        self = .worktree(path: URL(fileURLWithPath: path), label: label)
    }

    public var worktreeLabel: String? {
        if case .worktree(_, let label) = self { return label }
        return nil
    }

    /// The endpoint's own working directory — a worktree's path, or nil for a plain ref (the caller
    /// falls back to the repo root). B9: what `FileDiffPane.contentRoot` uses so "Open in Editor" and
    /// reveal act on `<worktreePath>/<file>` when comparing against a worktree.
    public var contentRoot: URL? {
        if case .worktree(let path, _) = self { return path }
        return nil
    }
}

extension RepositoryStore {
    /// ponytail: cap on untracked / per-path `--no-index` diffs, one git process each; a batched
    /// diff would lift it if agents' worktrees routinely exceed it.
    static let worktreeCompareFileCap = 200

    /// Labels of the worktrees whose uncommitted changes `compareDiff(base:head:)` includes: the
    /// head worktree, plus the base worktree when both are worktrees (tip-vs-tip). A worktree base
    /// against a ref head contributes only its HEAD (merge-base semantics, like ref/ref).
    public static func uncommittedLabels(base: CompareEndpoint, head: CompareEndpoint) -> [String] {
        switch (base, head) {
        case (.worktree(_, let b), .worktree(_, let h)): return [b, h]
        case (.ref, .worktree(_, let h)): return [h]
        default: return []
        }
    }

    /// Worktree endpoints count as their HEAD commit (all worktrees share one object database).
    public func compareCounts(base: CompareEndpoint, head: CompareEndpoint) async -> CompareCounts {
        await compareCounts(base: await revision(base), head: await revision(head))
    }

    public func compareCommits(base: CompareEndpoint, head: CompareEndpoint) async -> [CommitInfo] {
        await compareCommits(base: await revision(base), head: await revision(head))
    }

    /// - ref/ref: the existing `base...head` diff.
    /// - ref base, worktree head: `git diff --merge-base <ref>` inside the worktree (its working
    ///   tree vs the merge base — "what did this worktree do", uncommitted included) + untracked files.
    /// - worktree base, ref head: `<base worktree HEAD>...<ref>`.
    /// - worktree/worktree: the two working trees tip-vs-tip, one `diff --no-index` per path that
    ///   changed in either since their merge base (tracked or untracked).
    public func compareDiff(base: CompareEndpoint, head: CompareEndpoint) async -> [FileDiff] {
        switch (base, head) {
        case (.ref(let b), .ref(let h)):
            return await compareDiff(base: b, head: h)
        case (.worktree, .ref(let h)):
            return await compareDiff(base: await revision(base), head: h)
        case (.ref(let b), .worktree(let wt, _)):
            let out = (try? await git.run(["diff", "--no-color", "--merge-base", b], in: wt)) ?? ""
            var files = DiffParser.parse(out)
            for path in await untrackedPaths(in: wt).prefix(Self.worktreeCompareFileCap) {
                if let d = await noIndexDiff(nil, wt.appendingPathComponent(path), path: path, in: wt) { files.append(d) }
            }
            return files
        case (.worktree(let bw, _), .worktree(let hw, _)):
            let mergeBase = (try? await git.run(["merge-base", await revision(base), await revision(head)], in: url))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
            var paths = Set<String>()
            for wt in [bw, hw] {
                let changed = (try? await git.run(["diff", "-z", "--name-only", "--no-renames", mergeBase], in: wt)) ?? ""
                paths.formUnion(changed.split(separator: "\0").map(String.init))
                paths.formUnion(await untrackedPaths(in: wt))
            }
            var files: [FileDiff] = []
            for path in paths.sorted().prefix(Self.worktreeCompareFileCap) {
                let (b, h) = (bw.appendingPathComponent(path), hw.appendingPathComponent(path))
                let fm = FileManager.default
                if let d = await noIndexDiff(fm.fileExists(atPath: b.path) ? b : nil,
                                             fm.fileExists(atPath: h.path) ? h : nil, path: path, in: hw) {
                    files.append(d)
                }
            }
            return files
        }
    }

    /// A ref as-is; a worktree as its HEAD commit hash.
    private func revision(_ endpoint: CompareEndpoint) async -> String {
        switch endpoint {
        case .ref(let r): return r
        case .worktree(let path, _):
            return (try? await git.run(["rev-parse", "HEAD"], in: path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
        }
    }

    /// Resolves a worktree's real gitdir (`<main>/.git/worktrees/<name>`), the same way `gitDirURL()`
    /// resolves `self.url` — but for an arbitrary worktree path, so a fallback watcher for a Compare
    /// worktree endpoint not in the workspace can watch its commits too (B9; they land under the
    /// main repo's `.git/worktrees/<name>/`, not under the worktree's own root).
    public static func gitDir(forWorktree path: URL) -> URL? {
        resolveGitDir(path)
    }

    private func untrackedPaths(in wt: URL) async -> [String] {
        let out = (try? await git.run(["ls-files", "-z", "--others", "--exclude-standard"], in: wt)) ?? ""
        return out.split(separator: "\0").map(String.init)
    }

    /// `git diff --no-index` between two files (nil = `/dev/null`), path rewritten to `path`
    /// (git would report the absolute on-disk path). nil when identical or both missing.
    private func noIndexDiff(_ old: URL?, _ new: URL?, path: String, in dir: URL) async -> FileDiff? {
        guard old != nil || new != nil else { return nil }
        let out = (try? await git.run(["diff", "--no-color", "--no-index", "--", old?.path ?? "/dev/null", new?.path ?? "/dev/null"],
                                      in: dir, allowedExitCodes: [0, 1])) ?? ""
        guard let d = DiffParser.parse(out).first else { return nil }
        return FileDiff(path: path, isBinary: d.isBinary, hunks: d.hunks)
    }
}
