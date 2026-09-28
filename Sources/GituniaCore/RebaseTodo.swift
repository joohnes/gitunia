import Foundation

/// The todo list `git rebase -i` runs, built from what the Tidy Commits sheet picked — pure, so
/// the format and the "can this run at all" rules are testable without a repository.
public enum RebaseTodo {
    public enum Action: String, CaseIterable, Sendable {
        case pick, reword, squash, fixup, drop
    }

    public struct Line: Equatable, Sendable {
        public var action: Action
        public let hash: String
        public let subject: String
        /// For `reword`/`squash`: the message the (combined) commit ends up with. Never written
        /// into the todo itself — see `render(_:messageFiles:)`.
        public var newMessage: String?

        public init(action: Action = .pick, hash: String, subject: String, newMessage: String? = nil) {
            self.action = action; self.hash = hash; self.subject = subject; self.newMessage = newMessage
        }
    }

    /// Git's todo format, one line per commit, oldest first (the order given). A line with a
    /// message file (`messageFiles[index]`) sets its message with an `exec git commit --amend -F`
    /// right after it instead of prompting an editor: `reword` becomes `pick` + exec, `squash`
    /// becomes `fixup` + exec (the fixup keeps the group's message, the exec then replaces it).
    /// Exec rather than a scripted `GIT_EDITOR`: the message files survive a conflict stop, so a
    /// rebase resumed from the operation banner still applies them.
    public static func render(_ lines: [Line], messageFiles: [Int: String] = [:]) -> String {
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let subject = line.subject.replacingOccurrences(of: "\n", with: " ")
            guard let file = messageFiles[i], line.action == .reword || line.action == .squash else {
                out.append("\(line.action.rawValue) \(line.hash) \(subject)")
                continue
            }
            out.append("\(line.action == .reword ? "pick" : "fixup") \(line.hash) \(subject)")
            out.append("exec git commit --amend --allow-empty --no-verify -q -F \(shellQuoted(file))")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Why this todo can't run, or nil.
    public static func validate(_ lines: [Line]) -> String? {
        let kept = lines.filter { $0.action != .drop }
        guard let first = kept.first else { return "Every commit is dropped — keep at least one" }
        if first.action == .squash || first.action == .fixup {
            return "The oldest kept commit can't be squashed or fixed up — there's nothing before it to fold into"
        }
        return nil
    }

    /// "4 commits → 2, 1 dropped".
    public static func summary(_ lines: [Line]) -> String {
        let dropped = lines.filter { $0.action == .drop }.count
        let result = lines.filter { $0.action == .pick || $0.action == .reword }.count
        let n = lines.count
        return "\(n) commit\(n == 1 ? "" : "s") → \(result)" + (dropped > 0 ? ", \(dropped) dropped" : "")
    }

    /// Moves the line at `from` to `to` (clamped to the array's bounds) — the pure move both the
    /// sheet's drag-to-reorder and its ▲/▼ fallback buttons (B11) apply to `rows`.
    public static func moveLine(_ lines: [Line], from: Int, to: Int) -> [Line] {
        guard lines.indices.contains(from) else { return lines }
        var result = lines
        let line = result.remove(at: from)
        result.insert(line, at: min(max(to, 0), result.count))
        return result
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
