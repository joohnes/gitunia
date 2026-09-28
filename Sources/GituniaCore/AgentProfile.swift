import Foundation

/// Which commit authors are AI agents rather than the human supervising them. Each pattern is
/// matched against `"<name> <<email>>"`: case-insensitive substring, or a regular expression when
/// wrapped in slashes (`/^bot-\d+/`). An invalid regex matches nothing.
public struct AgentProfile: Codable, Equatable, Sendable {
    public var patterns: [String]

    /// ponytail: a guess at what today's agents commit as — substring matching means "claude"
    /// also catches a human named Claude; users fix that per repo or globally in Settings.
    public static let defaultPatterns = ["noreply@anthropic.com", "[bot]", "claude", "codex", "copilot", "agent@", "cursor"]

    public init(patterns: [String] = AgentProfile.defaultPatterns) { self.patterns = patterns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patterns = (try? c.decodeIfPresent([String].self, forKey: .patterns)) ?? Self.defaultPatterns
    }

    /// `--author=<pattern>` for `RepositoryStore.history(filterArgs:)` — one per pattern (git ORs
    /// multiple `--author`), so the "Agent commits" chip filters server-side across every page
    /// instead of only the loaded rows. `--author` is always a regex: a plain substring pattern is
    /// escaped into a literal match; a `/…/`-wrapped pattern is passed through raw. A trailing
    /// `--regexp-ignore-case` gives both forms the same case-insensitive semantics as `matches`.
    /// Empty when there are no non-blank patterns — no `--author` at all, not one matching nothing.
    public var gitAuthorArgs: [String] {
        let effective = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !effective.isEmpty else { return [] }
        let authorArgs = effective.map { p -> String in
            if p.count > 2, p.hasPrefix("/"), p.hasSuffix("/") {
                return "--author=\(p.dropFirst().dropLast())"
            }
            return "--author=\(NSRegularExpression.escapedPattern(for: p))"
        }
        return authorArgs + ["--regexp-ignore-case"]
    }

    /// ponytail: compiles regex patterns on every call — fine for a few hundred history rows;
    /// cache compiled `Regex`es if profiling ever says otherwise.
    public func matches(author: String, email: String) -> Bool {
        let haystack = "\(author) <\(email)>"
        return patterns.contains { raw in
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.count > 2, p.hasPrefix("/"), p.hasSuffix("/") {
                guard let regex = try? Regex(String(p.dropFirst().dropLast())).ignoresCase() else { return false }
                return haystack.contains(regex)
            }
            return !p.isEmpty && haystack.localizedCaseInsensitiveContains(p)
        }
    }
}
