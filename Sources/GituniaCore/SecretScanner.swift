import Foundation

/// A cheap, pure heuristic scan for obvious secrets in a diff before it's sent to a *cloud*
/// AI provider (local providers like Ollama never leave the machine, so they're not scanned).
/// This is not a security boundary — it catches the common, obvious cases (private keys, cloud
/// access keys, common token prefixes, `password=`/`secret=`/`token=` assignments) so the user
/// gets a chance to say no before a stray `.env` line goes out. Never returns the matched value,
/// only a human-readable label of what looked like a secret.
///
/// ponytail: regex heuristics, not a real secret scanner — extend the patterns if a common one
/// slips through, but don't chase every possible format.
public enum SecretScanner {
    private static let patterns: [(label: String, regex: NSRegularExpression)] = [
        ("a private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("an AWS access key ID", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("a GitHub token", #"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#),
        ("a Slack token", #"\bxox[bp]-[A-Za-z0-9-]{10,}\b"#),
        ("an API key", #"\bsk-[A-Za-z0-9]{20,}\b"#),
        ("a hardcoded password/secret/token", #"(?i)\b(password|secret|token)\s*[:=]\s*['"]?[A-Za-z0-9_\-/+]{12,}"#),
    ].map { (label, pattern) in (label, try! NSRegularExpression(pattern: pattern)) }

    /// Returns the distinct labels of secret-like patterns found in `diff`, in a stable order,
    /// or an empty array if none matched.
    public static func scan(_ diff: String) -> [String] {
        let range = NSRange(diff.startIndex..<diff.endIndex, in: diff)
        return patterns.compactMap { label, regex in
            regex.firstMatch(in: diff, range: range) != nil ? label : nil
        }
    }

    /// What looked like a secret, and in which file. Never carries the matched value.
    public struct Finding: Hashable, Sendable {
        public let path: String
        public let label: String
        /// Set only by `findings(inLog:)` — the unpushed commit the line was added in.
        public var commitHash = ""
        public var commitSubject = ""
    }

    /// `git log -p --format=%H%x1f%s` output: each `<hash>\u{1f}<subject>` marker line starts a
    /// commit, and findings carry it. One finding per (commit, path, label); see `findings(inDiff:)`.
    public static func findings(inLog log: String) -> [Finding] {
        var hash = "", subject = "", path = ""
        var seen = Set<Finding>()
        var result: [Finding] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if let sep = line.firstIndex(of: "\u{1f}"), line[..<sep].count >= 40, line[..<sep].allSatisfy(\.isHexDigit) {
                hash = String(line[..<sep])
                subject = String(line[line.index(after: sep)...])
                path = ""
                continue
            }
            if line.hasPrefix("+++ ") {
                path = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : String(line.dropFirst(4))
                continue
            }
            guard line.hasPrefix("+") else { continue }
            for label in scan(String(line.dropFirst())) {
                let finding = Finding(path: path, label: label, commitHash: hash, commitSubject: subject)
                if seen.insert(finding).inserted { result.append(finding) }
            }
        }
        return result
    }

    /// Scans only the *added* lines of a unified diff (`git diff --cached`), attributing each hit
    /// to the file named by the preceding `+++ b/<path>` header. Removed lines are ignored — taking
    /// a secret *out* shouldn't block the commit. One finding per (path, label). A diff has no
    /// `<hash>\u{1f}` marker lines, so this is `findings(inLog:)` with an empty commit.
    public static func findings(inDiff diff: String) -> [Finding] { findings(inLog: diff) }
}
