import Foundation

public enum GHError: Error, Equatable, Sendable, LocalizedError {
    case notInstalled
    case timeout
    /// Non-zero exit — carries gh's stderr (or stdout when stderr is empty).
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "GitHub CLI (gh) not found — install it with `brew install gh`, then `gh auth login`."
        case .timeout: return "gh did not respond in time."
        case .failed(let message): return message
        }
    }
}

/// Runs the GitHub CLI. Gitunia has no OAuth of its own — `gh auth login` is the whole setup.
public struct GHRunner: Sendable {
    /// Resolved once per run: a GUI app launched from Finder doesn't inherit the shell's PATH, so the
    /// usual Homebrew/user locations are searched too (`Executables.searchDirectories`).
    static let located: String? = find("gh")
    public static var isAvailable: Bool { located != nil }

    public let executable: String?
    let timeout: Double

    /// `executable`/`timeout` are for tests (a fake `gh` script, a short deadline).
    public init(executable: String? = nil, timeout: Double = 20) {
        self.executable = executable ?? Self.located
        self.timeout = timeout
    }

    /// `executable != nil` isn't enough to fake "gh not installed" in tests — an explicit nonexistent
    /// path (e.g. from a config value stale after an uninstall) must read as unavailable too, so this
    /// checks the file is actually there and executable, the same test `find(_:)` already applies.
    public var isAvailable: Bool { executable.map(FileManager.default.isExecutableFile(atPath:)) ?? false }

    public func run(_ args: [String], in repo: URL) async throws -> String {
        guard let executable else { throw GHError.notInstalled }
        let result: ProcessResult
        do {
            // Cancelling the losing task terminates the process (ProcessRunner's cancellation handler).
            result = try await withTimeout(seconds: timeout) {
                try await ProcessRunner.run(
                    executable: executable, arguments: args, currentDirectory: repo,
                    environment: ["GH_NO_UPDATE_NOTIFIER": "1", "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1",
                                  "GIT_TERMINAL_PROMPT": "0"]
                )
            }
        } catch AIError.timeout {
            throw GHError.timeout
        }
        guard result.exitCode == 0 else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GHError.failed(err.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err)
        }
        return result.stdout
    }

    static func find(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + Executables.searchDirectories
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Where a GUI app launched from Finder (which doesn't inherit the shell's PATH) also looks for CLIs.
enum Executables {
    static let searchDirectories = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
}
