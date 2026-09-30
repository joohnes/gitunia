import Foundation

/// Uses the locally installed `claude` CLI in print mode. Cloud provider (isLocal = false).
public struct ClaudeCLIProvider: CommitMessageProvider {
    public let name = "Claude CLI"
    public let isLocal = false
    public init() {}

    private static let extraPath = Executables.searchDirectories.joined(separator: ":")

    /// Structured output: the CLI validates the reply against this and returns it as
    /// `structured_output`, so the model can't answer with prose instead of a message.
    static let schema = #"{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"}},"required":["title","body"],"additionalProperties":false}"#

    static let arguments = [
        // `haiku` is the CLI alias for the newest Haiku — cheap and plenty for a commit message.
        "claude", "-p", "--model", "haiku",
        // Replace the coding-assistant system prompt and give it no tools: this is a one-shot
        // text task, not an agent session poking around the repository.
        "--system-prompt", PromptBuilder.instructions, "--tools", "",
        "--json-schema", schema, "--no-session-persistence", "--output-format", "json",
    ]

    public func generate(prompt: String) async throws -> CommitMessage {
        let result = try await withTimeout {
            try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: Self.arguments,
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
        return try Self.parse(result.stdoutData)
    }

    /// Envelope: `{"type":"result","result":"<model text>","structured_output":{...}, ...}`.
    /// Prefers the schema-validated object; falls back to scraping JSON out of `result`.
    static func parse(_ data: Data) throws -> CommitMessage {
        struct Envelope: Decodable {
            struct Message: Decodable { var title: String; var body: String? }
            var result: String?
            var structured_output: Message?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        if let message = envelope?.structured_output {
            return CommitMessage(title: message.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 body: (message.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try ModelOutput.parseCommitMessage(envelope?.result ?? String(decoding: data, as: UTF8.self))
    }
}
