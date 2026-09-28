import Foundation

/// Removes the attribution lines AI tools append to commit messages (`Co-Authored-By: Claude …`,
/// `🤖 Generated with …`). Pure — everything that isn't one of those lines stays byte-identical.
public enum TrailerStripper {
    /// Trailer keys (lowercased) always removed. `Signed-off-by` is deliberately absent: DCO sign-off
    /// is a human signal, so it's only dropped when its value is a bot (see `isAgentLine`).
    /// ponytail: fixed list, make it a setting if users ask for their own keys.
    static let agentKeys: Set<String> = ["co-authored-by", "generated-by", "generated-with", "assisted-by"]

    public static func strip(_ message: CommitMessage) -> CommitMessage {
        CommitMessage(title: message.title, body: strip(text: message.body))
    }

    public static func strip(text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { !isAgentLine($0) }
        guard kept.count != lines.count else { return text }
        // A removed trailer can leave two blank lines touching (the blank before it and the blank
        // after) — collapse runs of blank lines to one. Only reached when something was actually
        // removed (the guard above), so an untouched message's intentional double blank is never
        // touched and stays byte-identical.
        var collapsed: [String] = []
        for line in kept {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
            collapsed.append(line)
        }
        // Drop the now-empty trailing paragraph / blank lines the removed trailers leave behind.
        while let last = collapsed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }

    /// The lines `strip(text:)` would remove.
    public static func findings(in text: String) -> [String] {
        text.components(separatedBy: "\n").filter(isAgentLine)
    }

    private static func isAgentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("🤖 Generated with") { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[..<colon].lowercased()
        if agentKeys.contains(key) { return true }
        if key == "signed-off-by" {
            let value = trimmed[colon...].lowercased()
            return value.contains("noreply@anthropic") || value.contains("[bot]")
        }
        return false
    }
}
