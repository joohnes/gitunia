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
        guard let rule = rules.last(where: { $0.attributes["filter"] != nil && matches($0.pattern, path: path) }) else { return false }
        return rule.attributes["filter"] == "lfs"
    }

    /// `.gitignore`-style glob for a root `.gitattributes`: `*`, `?`, `**/`, `/**`, a leading `/`
    /// anchors, and a pattern without `/` matches the basename at any depth.
    // ponytail: no `[abc]` classes or `\` escapes, and a regex compiled per call — cache per rule if rows get slow.
    public static func matches(_ pattern: String, path: String) -> Bool {
        var pat = pattern
        let anchored = pat.hasPrefix("/")
        if anchored { pat.removeFirst() }
        let subject = (anchored || pat.contains("/")) ? path : (path as NSString).lastPathComponent
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
        return subject.range(of: regex + "$", options: .regularExpression) != nil
    }
}
