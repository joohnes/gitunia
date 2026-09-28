import Foundation

extension RepositoryStore {
    public var hasOutdatedSubmodules: Bool { submodules.contains { $0.state != .current } }

    /// Runs `git submodule status --recursive` only when `.gitmodules` exists, so the common
    /// no-submodule repo pays one stat per `refreshStatus()`. Verified it leaves `.git/index`
    /// untouched (mtime unchanged), so it can't feed the FSEvents refresh loop. `.gitmodules` is
    /// re-read only when its mtime moves; the recorded commits (`ls-files`) live in the index, so
    /// they're read every time.
    public func refreshSubmodules() async {
        let file = url.appendingPathComponent(".gitmodules")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            gitmodulesCache = nil
            if !submodules.isEmpty { submodules = [] }
            return
        }
        guard let out = try? await git.run(["submodule", "status", "--recursive"], in: url) else { return }
        var parsed = SubmoduleParser.parse(out)
        // Top-level only: nested submodules (from --recursive) live in their parent submodule's
        // .gitmodules/index, and a pathspec inside a submodule makes ls-files fail.
        let mtime = attrs[.modificationDate] as? Date
        let modules: [String: (name: String, url: String?, branch: String?)]
        if let cache = gitmodulesCache, cache.mtime == mtime {
            modules = cache.modules
        } else {
            modules = SubmoduleParser.parseGitmodules(
                (try? await git.run(["config", "--file", ".gitmodules", "--list"], in: url)) ?? "")
            gitmodulesCache = (mtime, modules)
        }
        let recorded = modules.isEmpty ? [:] : SubmoduleParser.parseRecorded(
            (try? await git.run(["ls-files", "-s", "-z", "--"] + modules.keys.sorted(), in: url)) ?? "")
        for i in parsed.indices {
            parsed[i].url = modules[parsed[i].path]?.url
            parsed[i].branch = modules[parsed[i].path]?.branch
            parsed[i].recordedCommit = recorded[parsed[i].path]
        }
        if parsed != submodules { submodules = parsed }
    }

    /// `git submodule add [-b <branch>] -- <url> <path>`. Always passes `-c protocol.file.allow=always`
    /// so a local path/`file://` URL the user typed works (git ≥ 2.38.1 refuses it otherwise); the URL
    /// is the user's own choice here, unlike a cloned repo's `.gitmodules` (CVE-2022-39253).
    public func addSubmodule(url remote: String, path: String, branch: String?) async -> GitError? {
        let branch = branch?.trimmingCharacters(in: .whitespaces) ?? ""
        return await attempt(["-c", "protocol.file.allow=always", "submodule", "add"]
            + (branch.isEmpty ? [] : ["-b", branch]) + ["--", remote.trimmingCharacters(in: .whitespaces), path])
    }

    /// Modern three-step removal: `submodule deinit -f`, `rm -f` (stages the gitlink + `.gitmodules`
    /// removal), then deletes `.git/modules/<name>` so a later re-add doesn't reuse the stale clone.
    /// The name is read from `.gitmodules` first (before `rm -f` removes that entry) since a
    /// submodule added with `--name` or later renamed has a name that differs from its path. Stops
    /// at the first failure. Disabled in the UI for nested submodules (not recorded in this repo's
    /// own index, so `.gitmodules` here has no entry for them).
    public func removeSubmodule(_ path: String) async -> GitError? {
        await attempt(["submodule", "deinit", path]) {
            let gitmodules = SubmoduleParser.parseGitmodules(
                (try? await git.run(["config", "--file", ".gitmodules", "--list"], in: url)) ?? "")
            let name = gitmodules[path]?.name ?? path
            try await git.run(["submodule", "deinit", "-f", "--", path], in: url)
            try await git.run(["rm", "-f", "--", path], in: url)
            if let modulesDir = gitDirURL()?.appendingPathComponent("modules").appendingPathComponent(name),
               FileManager.default.fileExists(atPath: modulesDir.path) {
                try FileManager.default.removeItem(at: modulesDir)
            }
        }
    }

    /// `git submodule sync --recursive`: copies `.gitmodules` URLs into each submodule's remote config.
    public func syncSubmodules() async -> GitError? {
        await attempt(["submodule", "sync", "--recursive"])
    }

    /// `git submodule update --init -- <path>`: initializes if needed and checks out the recorded commit.
    /// A nested submodule (from `--recursive`, not one of this repo's own `.gitmodules` paths) runs
    /// from its parent submodule's checkout instead, since it isn't recorded in this repo's own index.
    public func initSubmodule(_ path: String, configOverrides: [String] = []) async -> GitError? {
        let (dir, arg) = await submoduleLocation(path)
        return await attempt(configOverrides.flatMap { ["-c", $0] } + ["submodule", "update", "--init", "--", arg], in: dir)
    }

    /// `git submodule update --remote -- <path>`: fetches and checks out the tip of the `.gitmodules`
    /// `branch`, leaving the superproject's recorded commit behind (shows as `+`). Nested submodules
    /// run from their parent's checkout, as `initSubmodule` does.
    public func submoduleUpdateToRemote(_ path: String, configOverrides: [String] = []) async -> GitError? {
        let (dir, arg) = await submoduleLocation(path)
        return await attempt(configOverrides.flatMap { ["-c", $0] } + ["submodule", "update", "--remote", "--", arg], in: dir)
    }

    /// Splits a `--recursive` submodule path into where to run its commands from and what to pass.
    /// A path this repo's own `.gitmodules` records runs here with the full path unchanged — that
    /// check matters because the path itself can contain a "/" (e.g. "libs/a") without being nested.
    /// Anything else is nested: only its last component ("core" of "lib/core") is this repo's own
    /// `.gitmodules`/index concern; the rest ("lib") is where its parent submodule is checked out,
    /// and running there resolves the nested submodule's own `.gitmodules` the normal way.
    private func submoduleLocation(_ path: String) async -> (dir: URL, arg: String) {
        let gitmodules = SubmoduleParser.parseGitmodules(
            (try? await git.run(["config", "--file", ".gitmodules", "--list"], in: url)) ?? "")
        guard gitmodules[path] == nil, let slash = path.range(of: "/", options: .backwards) else { return (url, path) }
        return (url.appendingPathComponent(String(path[..<slash.lowerBound])), String(path[slash.upperBound...]))
    }

    /// `git log -1 <hash>` inside the submodule's checkout; nil when it isn't initialized (an empty
    /// folder would otherwise resolve to the superproject) or the commit isn't there.
    public func commitInfoForSubmodule(_ path: String, hash: String) async -> CommitInfo? {
        let dir = url.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) else { return nil }
        let out = try? await git.run(["log", "-1", hash, "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1e", "--date=short"], in: dir)
        return LogParser.parse(out ?? "").first
    }

    /// `git submodule update --init --recursive`: checks out the commits the superproject records.
    /// `configOverrides` become leading `-c` flags — tests need `protocol.file.allow=always`, since
    /// git ≥ 2.38.1 refuses local `file` transport for submodules ("fatal: transport 'file' not
    /// allowed", CVE-2022-39253) and only a command-line `-c` (not the superproject's own config)
    /// reaches the nested clone. The app never passes it.
    public func updateSubmodules(configOverrides: [String] = []) async -> GitError? {
        await attempt(["submodule", "update"]) {
            try await git.run(configOverrides.flatMap { ["-c", $0] } + ["submodule", "update", "--init", "--recursive"], in: url)
        }
    }

    public func worktrees() async throws -> [Worktree] {
        WorktreeParser.parse(try await git.run(["worktree", "list", "--porcelain"], in: url))
    }

    /// `git worktree add -b <branch> <path>` when `createBranch`, else `git worktree add <path> <branch>`
    /// (checks out an existing branch). The branch name is validated with `check-ref-format --branch` first.
    public func addWorktree(path: URL, branch: String, createBranch: Bool) async -> GitError? {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await branchNameProblem(trimmed) {
            return GitError(args: ["check-ref-format", "--branch", trimmed], exitCode: -1, stderr: problem)
        }
        return await attempt(["worktree"] + (createBranch ? ["add", "-b", trimmed, path.path] : ["add", path.path, trimmed]))
    }

    /// `git worktree remove [--force] <path>`. Without `force` git refuses a worktree with modified or
    /// untracked files; that stderr comes back so the caller can offer a forced retry.
    public func removeWorktree(_ wt: Worktree, force: Bool) async -> GitError? {
        await attempt(["worktree", "remove"] + (force ? ["--force"] : []) + [wt.path])
    }

    /// `git worktree prune`: drops administrative entries for worktrees whose folder is gone.
    public func pruneWorktrees() async -> GitError? {
        await attempt(["worktree", "prune"])
    }
}
