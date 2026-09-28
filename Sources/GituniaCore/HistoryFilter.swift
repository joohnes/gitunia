import Foundation

/// Parses the free-text filter field above `HistoryView`'s commit list into `git log` arguments.
///
/// Grammar: whitespace-separated tokens, `"quoted phrases"` group into a single token (spaces
/// inside count as one word/value). A token of the form `author:<value>`, `path:<value>`,
/// `since:<value>` or `until:<value>` sets that field (last one wins if repeated); anything else,
/// including an unrecognized `foo:bar` prefix, is free text matched against the subject/body.
///
/// Verified against real git (2.50.1) in a temp repo: `git log --since=<garbage>` never errors —
/// it exits 0 with either the unfiltered list or an empty one depending on how approxidate's
/// fuzzy word-scanning happens to land, so there is no exit-code/stderr signal to detect an
/// invalid date from. `isValidDate` instead validates a known-good, documented subset of
/// approxidate's grammar (ISO dates, `yesterday`/`today`/`now`, `N <unit>(s) ago`, `N.unit(s)`)
/// and flags everything else as invalid, even though a handful of stranger inputs git itself
/// would still (unpredictably) accept.
/// ponytail: not a full approxidate grammar — good enough to catch the typo case the plan asks
/// for ("since:novimber"); extend `isValidDate`'s patterns if a real approxidate form starts
/// getting flagged as invalid.
public struct HistoryFilter: Equatable, Sendable {
    public var words: [String] = []
    public var author: String?
    public var path: String?
    public var since: String?
    public var until: String?

    public init() {}

    public static func parse(_ text: String) -> HistoryFilter {
        var filter = HistoryFilter()
        for token in tokenize(text) {
            if let value = value(in: token, prefix: "author:") { filter.author = value }
            else if let value = value(in: token, prefix: "path:") { filter.path = value }
            else if let value = value(in: token, prefix: "since:") { filter.since = value }
            else if let value = value(in: token, prefix: "until:") { filter.until = value }
            else if !token.isEmpty { filter.words.append(token) }
        }
        return filter
    }

    private static func value(in token: String, prefix: String) -> String? {
        guard token.hasPrefix(prefix) else { return nil }
        let value = String(token.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// Splits on whitespace, except inside `"..."` — quotes are stripped, and a quoted run can
    /// contain spaces without breaking the token in two (so `author:"Jane Doe"` and `"two words"`
    /// each become one token).
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in text {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// `nil` when there's nothing to validate (field unset or blank); otherwise whether the date
    /// text matches a recognized subset of git's `approxidate` grammar. See the type doc comment.
    public static func isValidDate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if ["yesterday", "today", "now"].contains(t.lowercased()) { return true }
        // ISO date, optionally with a time: 2026-09-01[ 12:30[:00]]
        if t.range(of: #"^\d{4}-\d{2}-\d{2}(\s+\d{2}:\d{2}(:\d{2})?)?$"#, options: .regularExpression) != nil {
            return true
        }
        // "N unit(s) ago": 3 days ago, 2 weeks ago, 1 month ago
        if t.range(of: #"^\d+\s+(second|minute|hour|day|week|month|year)s?\s+ago$"#, options: .regularExpression, range: nil, locale: nil) != nil {
            return true
        }
        // Dotted form: 2.weeks, 2.weeks.ago
        if t.range(of: #"^\d+\.(second|minute|hour|day|week|month|year)s?(\.ago)?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// The first invalid `since`/`until` value, if any — drives the inline hint in `HistoryView`.
    public var invalidDateField: (label: String, value: String)? {
        if let since, !Self.isValidDate(since) { return ("since", since) }
        if let until, !Self.isValidDate(until) { return ("until", until) }
        return nil
    }

    public var isEmpty: Bool {
        words.isEmpty && author == nil && path == nil && since == nil && until == nil
    }

    /// Git arguments for `git log`. `path`, when present, must come last (as `-- <path>`) — callers
    /// append this after any other fixed arguments (branch, `-n`, `--skip`, `--pretty`).
    /// Multiple free-text words each get their own `--grep -i`, combined with `--all-match` so a
    /// commit's subject/body must match every word, not just one (verified against real git:
    /// `--all-match` with a single `--grep` is a no-op, so it's safe to always include when there's
    /// more than one word).
    public var gitArgs: [String] {
        var args: [String] = []
        if !words.isEmpty {
            if words.count > 1 { args.append("--all-match") }
            for word in words { args += ["--grep=\(word)", "-i"] }
        }
        if let author { args += ["--author=\(author)", "-i"] }
        if let since, Self.isValidDate(since) { args.append("--since=\(since)") }
        if let until, Self.isValidDate(until) { args.append("--until=\(until)") }
        if let path { args += ["--", path] }
        return args
    }
}
