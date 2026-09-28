import Foundation
import GituniaCore

/// Throwaway git repos. `GituniaCoreTests/TestHelpers.swift` has the same helper for that target.
enum TestRepo {
    /// A fixed instant so commit hashes are stable across runs.
    static let fixedDate = Date(timeIntervalSince1970: 1_767_322_245) // 2026-01-02T03:04:05Z

    /// `git commit` with a pinned author/committer date and identity. `args` is everything after `commit`.
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
    /// off; writes `files` and commits them (an empty commit when there are none).
    @discardableResult
    static func make(at url: URL? = nil, files: [String: String] = [:],
                     user: String = "Test", email: String = "test@example.com") async throws -> URL {
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
        if files.isEmpty {
            try await commit(at: url, args: ["-q", "--allow-empty", "-m", "init"], user: user, email: email)
        } else {
            _ = try await git.run(["add", "."], in: url)
            try await commit(at: url, args: ["-q", "-m", "init"], user: user, email: email)
        }
        return url
    }
}
