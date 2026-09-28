import Foundation

/// The only way the app talks to git.
public struct GitRunner: Sendable {
    public init() {}

    /// The git binary, resolved once per run: the first `git` on PATH, except that `/usr/bin/git`
    /// (what a Finder-launched app finds) is Apple's xcrun shim, which re-resolves the developer
    /// dir on every launch — measured ~5ms per call, 105–165ms vs ~60ms for a whole commit. Asking
    /// `xcrun --find git` once yields the very binary the shim would exec, so it's the same git.
    static let executable: String = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let found = path.split(separator: ":").map { "\($0)/git" }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        guard found == "/usr/bin/git" else { return found }
        let xcrun = Process(), out = Pipe()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "git"]
        xcrun.standardOutput = out
        xcrun.standardError = FileHandle.nullDevice
        guard (try? xcrun.run()) != nil else { return found }
        let real = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        xcrun.waitUntilExit()
        return xcrun.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: real) ? real : found
    }()

    /// Repo-local `.git/config` can point `core.fsmonitor`, `diff.external` or a textconv filter at
    /// an arbitrary command, which then runs with no user action beyond opening/refreshing the repo
    /// (C1). `-c core.fsmonitor=false` is safe to pass on every invocation — it only matters to the
    /// handful of commands that consult it. `--no-ext-diff`/`--no-textconv` are diff options, so they
    /// only get added to the diff-producing subcommands that accept them; other commands (e.g.
    /// `status`, `commit`) would fail with "unknown option" if we appended them unconditionally.
    private static func hardenedArguments(_ args: [String]) -> [String] {
        // `--no-optional-locks` (H1) is a top-level git option (must precede the subcommand, unlike
        // the diff flags below) that skips *optional* index-refresh locking — real writes (commit,
        // add, reset, …) still take the lock they need, but a background `status` no longer rewrites
        // `.git/index`'s mtime, which otherwise re-triggers the FSEvents watcher on every refresh.
        // Safe on every call, so it lives in the fixed prefix rather than being conditioned on the
        // subcommand.
        let fixedPrefix = ["--no-optional-locks", "-c", "core.quotePath=false", "-c", "core.fsmonitor=false"]
        var git = fixedPrefix + args
        guard let sub = args.first else { return git }
        let diffLike = sub == "diff" || sub == "show" || sub == "log"
            || (sub == "stash" && args.dropFirst().first == "show")
        if diffLike {
            // Insert right after the subcommand token(s) so it lands before any `--` pathspec
            // separator later in `args`.
            let subTokens = (sub == "stash") ? 2 : 1
            git.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: fixedPrefix.count + subTokens)
        }
        return git
    }

    private static func environment(literalPathspecs: Bool) -> [String: String] {
        var env = ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        // `GIT_LITERAL_PATHSPECS=1` (C2/L9): treats every pathspec argument as a literal path, never
        // glob/magic syntax — so a file named e.g. `a[1].txt` can't accidentally also match `a1.txt`
        // on stage/unstage/discard/clean/stash. Opt-in per call, not global: verified against real
        // git 2.50.1 that setting it unconditionally breaks plain `git stash push -u` with *no*
        // explicit pathspec — the untracked file silently isn't removed from the working tree even
        // though the command reports success. So this is only set on the specific calls that pass an
        // explicit pathspec caller-side (see call sites), which replaces the old per-path
        // `:(literal)` prefix without that regression.
        if literalPathspecs { env["GIT_LITERAL_PATHSPECS"] = "1" }
        return env
    }

    /// The one place a git process is launched: exit code checked against `allowedExitCodes`, and
    /// a launch failure (e.g. the repo folder vanished) wrapped in a `GitError` with exit code -1.
    /// `CancellationError` passes through untouched.
    private func exec(
        _ args: [String], in repo: URL, stdin: String?, allowedExitCodes: Set<Int32>,
        literalPathspecs: Bool, extraEnvironment: [String: String] = [:]
    ) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: Self.executable,
                arguments: Self.hardenedArguments(args),
                currentDirectory: repo,
                environment: Self.environment(literalPathspecs: literalPathspecs).merging(extraEnvironment) { $1 },
                stdin: stdin
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw GitError(args: args, exitCode: -1, stderr: error.localizedDescription)
        }
        guard allowedExitCodes.contains(result.exitCode) else {
            throw GitError(args: args, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    public func runData(
        _ args: [String],
        in repo: URL,
        stdin: String? = nil,
        allowedExitCodes: Set<Int32> = [0],
        literalPathspecs: Bool = false
    ) async throws -> Data {
        try await exec(args, in: repo, stdin: stdin, allowedExitCodes: allowedExitCodes, literalPathspecs: literalPathspecs).stdoutData
    }

    @discardableResult
    public func run(
        _ args: [String],
        in repo: URL,
        stdin: String? = nil,
        allowedExitCodes: Set<Int32> = [0],
        literalPathspecs: Bool = false
    ) async throws -> String {
        String(decoding: try await runData(args, in: repo, stdin: stdin, allowedExitCodes: allowedExitCodes, literalPathspecs: literalPathspecs), as: UTF8.self)
    }

    /// Like `run`, but also returns stderr on success — git writes most remote-command
    /// progress/summary text there even when the command succeeds.
    public func runCombined(
        _ args: [String],
        in repo: URL,
        stdin: String? = nil,
        allowedExitCodes: Set<Int32> = [0],
        literalPathspecs: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) async throws -> (stdout: String, stderr: String) {
        let result = try await exec(args, in: repo, stdin: stdin, allowedExitCodes: allowedExitCodes,
                                    literalPathspecs: literalPathspecs, extraEnvironment: extraEnvironment)
        return (result.stdout, result.stderr)
    }
}
