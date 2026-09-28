import Foundation

public enum PromptBuilder {
    public static func build(stat: String, diff: String, limit: Int) -> String {
        let body: String
        if diff.count > limit {
            body = String(diff.prefix(limit)) + "\n[diff truncated]"
        } else {
            body = diff
        }
        return """
        You write git commit messages following the Conventional Commits specification.
        Rules:
        - Title format: <type>(<optional scope>): <summary>, max 72 characters, imperative mood, no trailing period.
        - Allowed types: feat, fix, refactor, docs, chore, test, style, perf, build, ci.
        - Body: 1-4 short lines explaining WHY the change was made, not what. Empty string if the title says it all.
        - Respond with ONLY a JSON object: {"title": "...", "body": "..."}. No markdown, no commentary.

        Diff stat:
        \(stat)

        Staged diff:
        \(body)
        """
    }
}
