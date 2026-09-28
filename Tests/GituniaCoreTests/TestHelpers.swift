import Foundation
@testable import GituniaCore

enum TestHelpers {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitunia-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a git repo with one commit containing README.md.
    static func makeTempRepo() async throws -> URL {
        try await TestRepo.make(files: ["README.md": "hello\n"])
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes — for debounced/async
    /// writes, where a fixed sleep flakes on slow CI runners. Returns quietly on timeout; the
    /// caller's assertion reports the failure.
    @MainActor
    static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func write(_ text: String, to repo: URL, _ name: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// Throwaway git repos. `GituniaTests/TestRepo.swift` has the same helper for that target.
enum TestRepo {
    /// `git init -b master` at `url` (a fresh temp dir by default) with a local identity and signing
    /// off; writes `files`, then commits them as `message` (an empty commit when there are none)
    /// unless `commit` is false.
    @discardableResult
    static func make(at url: URL? = nil, files: [String: String] = [:], commit: Bool = true,
                     message: String = "init", user: String = "Test", email: String = "test@example.com") async throws -> URL {
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
            _ = try await git.run(["commit", "-q", "--allow-empty", "-m", message], in: url)
        } else {
            _ = try await git.run(["add", "."], in: url)
            _ = try await git.run(["commit", "-q", "-m", message], in: url)
        }
        return url
    }
}
