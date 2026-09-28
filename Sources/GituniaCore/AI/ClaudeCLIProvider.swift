import Foundation

/// Uses the locally installed `claude` CLI in print mode. Cloud provider (isLocal = false).
public struct ClaudeCLIProvider: CommitMessageProvider {
    public let name = "Claude CLI"
    public let isLocal = false
    public init() {}

    private static let extraPath = Executables.searchDirectories.joined(separator: ":")

    public func generate(prompt: String) async throws -> CommitMessage {
        let result = try await withTimeout {
            try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: ["claude", "-p", "--output-format", "json"],
                environment: ["PATH": Self.extraPath + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")],
                stdin: prompt
            )
        }
        if result.exitCode == 127 || result.stderr.contains("No such file") {
            throw AIError.providerUnavailable("`claude` CLI not found. Install Claude Code or switch provider in Settings.")
        }
        guard result.exitCode == 0 else {
            throw AIError.providerUnavailable("claude exited with \(result.exitCode):\n\(result.stderr)")
        }
        // Envelope: {"type":"result","result":"<model text>", ...}
        struct Envelope: Decodable { var result: String? }
        let stdout = result.stdout
        let text = (try? JSONDecoder().decode(Envelope.self, from: result.stdoutData))?.result ?? stdout
        return try ModelOutput.parseCommitMessage(text)
    }
}
