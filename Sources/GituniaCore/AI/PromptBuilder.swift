import Foundation

public enum PromptBuilder {
    /// The task and output rules. Also sent as the Claude CLI's system prompt: in print mode it
    /// otherwise runs as a coding assistant and may answer a large diff with "what should I do?".
    public static let instructions = """
        You write git commit messages following the Conventional Commits specification.
        Rules:
        - Title format: <type>(<optional scope>): <summary>, max 72 characters, imperative mood, no trailing period.
        - Allowed types: feat, fix, refactor, docs, chore, test, style, perf, build, ci.
        - Body: 1-4 short lines explaining WHY the change was made, not what. Empty string if the title says it all.
        - Respond with ONLY a JSON object: {"title": "...", "body": "..."}. No markdown, no commentary.
        """

    public static func build(stat: String, diff: String, limit: Int) -> String {
        let body: String
        if diff.count > limit {
            body = String(diff.prefix(limit)) + "\n[diff truncated]"
        } else {
            body = diff
        }
        // The rules are repeated after the diff: with a long diff a model follows what it read
        // last, not the instructions tens of thousands of characters above.
        return """
        \(instructions)

        Diff stat:
        \(stat)

        Staged diff:
        \(body)

        Now write the commit message for the diff above. Respond with ONLY the JSON object {"title": "...", "body": "..."}.
        """
    }
}
