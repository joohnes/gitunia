import Foundation

extension WorkspaceScanner {
    /// Linked worktrees of `repos` that live inside `root` but that the directory walk can't reach —
    /// agents typically put them *inside* the main repo (`<repo>/.claude/worktrees/<name>`), which
    /// is both inside a found repo and hidden. Read from `<repo>/.git/worktrees/*/gitdir` (each holds
    /// the worktree's `.git` file path, realpath'd by git, e.g. `/private/var/...`), no git process.
    /// Returned as realpaths (what `contentsOfDirectory` hands the walk too, e.g. `/private/var/...`
    /// under a `/var/...` root); sibling worktrees the walk already found are returned too — the
    /// caller dedupes by resolved path.
    /// Prunable worktrees (folder deleted) are skipped.
    static func linkedWorktrees(of repos: [URL], inside root: URL) -> [URL] {
        let fm = FileManager.default
        let realRoot = root.resolvingSymlinksInPath().path
        var out: [URL] = []
        for repo in repos {
            let admin = repo.appendingPathComponent(".git/worktrees")
            guard let entries = try? fm.contentsOfDirectory(atPath: admin.path) else { continue }
            for entry in entries.sorted() {
                guard let gitdir = try? String(contentsOf: admin.appendingPathComponent("\(entry)/gitdir"), encoding: .utf8) else { continue }
                let worktree = URL(fileURLWithPath: gitdir.trimmingCharacters(in: .whitespacesAndNewlines))
                    .deletingLastPathComponent().resolvingSymlinksInPath().path
                guard worktree.hasPrefix(realRoot + "/"), fm.fileExists(atPath: worktree + "/.git") else { continue }
                let url = URL(fileURLWithPath: worktree)
                if !out.contains(url) { out.append(url) }
            }
        }
        return out
    }
}
