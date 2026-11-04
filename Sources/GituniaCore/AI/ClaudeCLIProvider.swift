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
        // Skip the user's ~/.claude setup (hooks, plugins, MCP servers, skills): loading it
        // roughly doubled the call. Not `--bare` — that drops OAuth, i.e. subscription logins.
        "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
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
        if let failure = Self.failure(exitCode: result.exitCode, stdout: result.stdoutData, stderr: result.stderr) {
            throw failure
        }
        return try Self.parse(result.stdoutData)
    }

    /// Turns a failed run into an error that says what went wrong. With `--output-format json`
    /// the CLI reports API and login problems as a result envelope on **stdout**
    /// (`"is_error": true`, the reason in `result`) and leaves stderr empty, so stderr alone used
    /// to read as a bare "claude exited with 1:". Returns nil when the run succeeded.
    static func failure(exitCode: Int32, stdout: Data, stderr: String) -> AIError? {
        struct ErrorEnvelope: Decodable { var is_error: Bool?; var result: String?; var subtype: String? }
        let stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: stdout)
        let reportedError = envelope?.is_error == true

        // `/usr/bin/env` exits 127 both for a missing `claude` and for an npm-installed `claude`
        // whose `#!/usr/bin/env node` can't find node on a GUI app's PATH (nvm, fnm, volta…).
        if exitCode == 127 || (!reportedError && stderr.contains("No such file")) {
            if stderr.contains("node") {
                return .providerUnavailable("`claude` was found but `node` was not: an app started from the Dock doesn't see your shell's PATH. Install Claude Code with the native installer (curl -fsSL https://claude.ai/install.sh | bash) or link node into /usr/local/bin.")
            }
            return .providerUnavailable("`claude` CLI not found. Install Claude Code or switch provider in Settings.")
        }
        guard exitCode != 0 || reportedError else { return nil }

        if stderr.contains("unknown option") || stderr.contains("unknown argument") {
            return .providerUnavailable("Your Claude Code CLI is too old for Gitunia (\(stderr)). Run `claude update` in a terminal.")
        }
        let reason = envelope?.result?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = [reason, stderr.isEmpty ? nil : stderr]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        let lowered = message.lowercased()
        if lowered.contains("/login") || lowered.contains("not logged in") || lowered.contains("invalid api key")
            || lowered.contains("authentication") || lowered.contains("oauth") {
            return .providerUnavailable("Claude Code is not signed in: \(message)\nRun `claude` in a terminal and sign in with /login, then try again.")
        }
        if message.isEmpty {
            let detail = envelope?.subtype.map { " (\($0))" } ?? ""
            return .providerUnavailable("claude exited with \(exitCode)\(detail) without saying why. Run `claude -p hello` in a terminal to see the error.")
        }
        return .providerUnavailable("claude exited with \(exitCode):\n\(message)")
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
