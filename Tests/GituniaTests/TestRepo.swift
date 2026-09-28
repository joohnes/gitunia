import Foundation
import GituniaCore

/// Throwaway git repos. `GituniaCoreTests/TestHelpers.swift` has the same helper for that target.
enum TestRepo {
    /// A fixed instant so `git commit` hashes (and any rendered dates) are stable across runs —
    /// real-clock author/committer dates are the #1 source of non-deterministic render output
    /// (D18): they change the commit hash every run, which then shows up in any abbreviated SHA
    /// or absolute date a view renders.
    static let fixedDate = Date(timeIntervalSince1970: 1_767_322_245) // 2026-01-02T03:04:05Z

    /// Commits with a fixed author/committer date (and identity) so the resulting hash is stable
    /// across runs. Fixtures that make extra commits beyond `make`'s initial one should call this
    /// instead of shelling out to `git commit` directly. `args` is everything after `commit`
    /// (e.g. `["-q", "-m", "message"]` or `["-q", "--allow-empty", "-m", "message", "--author=…"]`
    /// — an explicit `--author=`/`--date=` in `args` takes precedence over `user`/`email`/`date`
    /// for the author identity, but the committer date can only be set via environment, so this
    /// always pins it.
    @discardableResult
    static func commit(at url: URL, args: [String], date: Date = fixedDate,
                       user: String = "Test", email: String = "test@example.com") async throws -> String {
        let iso = ISO8601DateFormatter().string(from: date)
        let env = [
            "GIT_AUTHOR_NAME": user, "GIT_AUTHOR_EMAIL": email, "GIT_AUTHOR_DATE": iso,
            "GIT_COMMITTER_NAME": user, "GIT_COMMITTER_EMAIL": email, "GIT_COMMITTER_DATE": iso,
        ]
        let (out, _) = try await GitRunner().runCombined(["commit"] + args, in: url, extraEnvironment: env)
        return out
    }

    /// `git init -b master` at `url` (a fresh temp dir by default) with a local identity and signing
    /// off; writes `files`, then commits them as `message` (an empty commit when there are none)
    /// unless `commit` is false. The initial commit uses a fixed author/committer `date` (default
    /// `fixedDate`) so its hash — and any date rendered from it — is stable across runs (D18).
    @discardableResult
    static func make(at url: URL? = nil, files: [String: String] = [:], commit: Bool = true,
                     message: String = "init", user: String = "Test", email: String = "test@example.com",
                     date: Date = fixedDate) async throws -> URL {
        let url = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let git = GitRunner()
        for args in [["init", "-q", "-b", "master"], ["config", "user.email", email], ["config", "user.name", user],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: url)
        }
        for (path, text) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        guard commit else { return url }
        if files.isEmpty {
            _ = try await Self.commit(at: url, args: ["-q", "--allow-empty", "-m", message], date: date, user: user, email: email)
        } else {
            _ = try await git.run(["add", "."], in: url)
            _ = try await Self.commit(at: url, args: ["-q", "-m", message], date: date, user: user, email: email)
        }
        return url
    }

    /// Pins `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE`/name/email as real process environment variables
    /// for the duration of `body`, then restores whatever was there before. For fixtures that reach
    /// git through a `RepositoryStore`/`WorkspaceStore` call (autostash, stash, …) rather than
    /// `TestRepo.commit` directly — `GitRunner` always inherits the process environment
    /// (`ProcessRunner.run` starts from `ProcessInfo.processInfo.environment`), so this is the only
    /// way to pin the date/identity of a commit made by code we don't own without editing it.
    @MainActor
    static func withFixedGitClock<T>(date: Date = fixedDate, user: String = "Test", email: String = "test@example.com",
                                     _ body: () async throws -> T) async rethrows -> T {
        let iso = ISO8601DateFormatter().string(from: date)
        let keys = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE",
                    "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE"]
        let values = [user, email, iso, user, email, iso]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        for (key, value) in zip(keys, values) { setenv(key, value, 1) }
        defer {
            for (key, old) in zip(keys, previous) {
                if let old { setenv(key, old, 1) } else { unsetenv(key) }
            }
        }
        return try await body()
    }

    /// A deterministic per-test temp root (`$TMPDIR/gitunia-render-fixed/<name>/`), cleaned before
    /// use — for fixtures whose view renders a full temp path (hooks footer, manage workspace)
    /// rather than just a last path component, so a `UUID()`-named folder would show up as noise.
    static func fixedRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-render-fixed", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
