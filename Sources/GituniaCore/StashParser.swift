import Foundation

/// Parses `git stash list --format=%gd%x1f%s` (a machine-readable format string rather than
/// git's human-facing default, same reasoning as `LogParser`'s `%x1e`/`%x1f` delimiters).
///
/// `%gd` gives the reflog selector, e.g. `stash@{0}`; `%s` gives the subject, which git writes as
/// either `"On <branch>: <message>"` (an explicit `-m` message) or `"WIP on <branch>: <message>"`
/// (the default, no `-m` given).
public enum StashParser {
    public static func parse(_ text: String) -> [StashEntry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? entry(selector: parts[0], subject: parts[1]) : nil
        }
    }

    /// `stash@{2}` + `%s` → entry; nil when the selector has no `{N}`.
    static func entry(selector: Substring, subject: Substring) -> StashEntry? {
        guard let index = index(from: selector) else { return nil }
        let (branch, message) = splitSubject(String(subject))
        return StashEntry(index: index, branch: branch, message: message)
    }

    /// "stash@{2}" -> 2
    private static func index(from ref: Substring) -> Int? {
        guard let open = ref.firstIndex(of: "{"), let close = ref.firstIndex(of: "}"), open < close else { return nil }
        return Int(ref[ref.index(after: open)..<close])
    }

    /// Falls back to putting the whole subject in `message` with an empty branch if it doesn't
    /// match either known shape (older git, or a custom message that itself starts with "On ").
    private static func splitSubject(_ subject: String) -> (branch: String, message: String) {
        for prefix in ["On ", "WIP on "] {
            guard subject.hasPrefix(prefix) else { continue }
            let rest = subject.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let branch = String(rest[rest.startIndex..<colon])
            let message = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (branch, message)
        }
        return ("", subject)
    }
}
