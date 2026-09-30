import Foundation

/// One non-comment line of `.gitattributes`: `name` → `"true"`, `-name` → `"false"`,
/// `!name` → `"!"` (unspecified), `name=value` → `value`.
public struct AttributeRule: Sendable, Equatable {
    public var pattern: String
    public var attributes: [String: String]

    public init(pattern: String, attributes: [String: String]) {
        self.pattern = pattern
        self.attributes = attributes
    }
}

public enum GitAttributes {
    public static func parse(_ text: String) -> [AttributeRule] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let pattern = fields.first, !pattern.hasPrefix("#") else { return nil }
            var attributes: [String: String] = [:]
            for field in fields.dropFirst() {
                if field.hasPrefix("-") { attributes[String(field.dropFirst())] = "false" }
                else if field.hasPrefix("!") { attributes[String(field.dropFirst())] = "!" }
                else if let eq = field.firstIndex(of: "=") { attributes[String(field[..<eq])] = String(field[field.index(after: eq)...]) }
                else { attributes[field] = "true" }
            }
            return AttributeRule(pattern: pattern, attributes: attributes)
        }
    }

    /// Git semantics: the last matching line that mentions `filter` decides.
    public static func isLFSTracked(_ path: String, rules: [AttributeRule]) -> Bool {
        LFSMatcher(rules).isTracked(path)
    }

    /// `.gitignore`-style glob for a root `.gitattributes`: `*`, `?`, `**/`, `/**`, a leading `/`
    /// anchors, and a pattern without `/` matches the basename at any depth.
    // ponytail: no `[abc]` classes or `\` escapes.
    public static func matches(_ pattern: String, path: String) -> Bool {
        compile(pattern)?.matches(path) ?? false
    }

    /// A compiled glob: the regex plus whether it tests the full path or only the basename.
    struct Glob {
        let regex: NSRegularExpression
        let fullPath: Bool
        func matches(_ path: String) -> Bool {
            let subject = fullPath ? path : (path as NSString).lastPathComponent
            return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }
    }

    static func compile(_ pattern: String) -> Glob? {
        var pat = pattern
        let anchored = pat.hasPrefix("/")
        if anchored { pat.removeFirst() }
        var regex = "^"
        var chars = Substring(pat)
        while let c = chars.first {
            if chars.hasPrefix("**/") { regex += "(?:.*/)?"; chars = chars.dropFirst(3) }
            else if chars.hasPrefix("/**"), chars.count == 3 { regex += "/.*"; chars = chars.dropFirst(3) }
            else if chars.hasPrefix("**") { regex += ".*"; chars = chars.dropFirst(2) }
            else if c == "*" { regex += "[^/]*"; chars = chars.dropFirst() }
            else if c == "?" { regex += "[^/]"; chars = chars.dropFirst() }
            else { regex += NSRegularExpression.escapedPattern(for: String(c)); chars = chars.dropFirst() }
        }
        guard let compiled = try? NSRegularExpression(pattern: regex + "$") else { return nil }
        return Glob(regex: compiled, fullPath: anchored || pat.contains("/"))
    }
}

/// `.gitattributes` `filter` rules compiled once — the Changes list asks per visible row, and
/// compiling each rule's regex per call dominated scrolling a large LFS repo.
public struct LFSMatcher {
    private let rules: [(glob: GitAttributes.Glob, isLFS: Bool)]

    public init(_ rules: [AttributeRule]) {
        self.rules = rules.compactMap { rule in
            guard let filter = rule.attributes["filter"], let glob = GitAttributes.compile(rule.pattern) else { return nil }
            return (glob, filter == "lfs")
        }
    }

    public func isTracked(_ path: String) -> Bool {
        rules.last { $0.glob.matches(path) }?.isLFS ?? false
    }
}
