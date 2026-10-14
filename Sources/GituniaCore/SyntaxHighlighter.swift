import Foundation

public enum SyntaxLanguage: Sendable, Equatable {
    case swift, javascript, python, go, rust, ruby, java, shell, json, yaml, markdown
    case c, php, css, markup, sql, lua, toml, other

    public static func from(fileExtension: String?) -> SyntaxLanguage {
        switch (fileExtension ?? "").lowercased() {
        case "swift": .swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts": .javascript
        case "py", "pyi": .python
        case "go": .go
        case "rs": .rust
        case "rb", "rake", "gemspec", "ex", "exs": .ruby
        case "java", "kt", "kts", "scala", "groovy", "gradle", "dart": .java
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cs", "zig": .c
        case "php": .php
        case "css", "scss", "sass", "less": .css
        case "html", "htm", "xml", "xhtml", "svg", "vue", "svelte", "astro", "plist", "xib", "storyboard": .markup
        case "sql": .sql
        case "lua": .lua
        case "toml", "ini", "cfg", "conf", "env", "properties", "tf", "hcl": .toml
        case "sh", "zsh", "bash", "fish": .shell
        case "json", "jsonc", "json5": .json
        case "yml", "yaml": .yaml
        case "md", "markdown", "mdx": .markdown
        default: .other
        }
    }

    var lineComment: String? {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml: "#"
        case .sql, .lua: "--"
        case .markdown, .json, .css, .markup, .other: nil
        default: "//"
        }
    }

    /// Static so the tokenizer's per-word lookup doesn't rebuild a `Set` every time.
    var keywords: Set<String> { Self.keywordSets[self] ?? [] }

    private static let keywordSets: [SyntaxLanguage: Set<String>] = [
        .swift: ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "async", "await", "public", "private", "internal", "static", "self", "true", "false", "nil", "init", "some", "any", "where"],
        .javascript: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "class", "extends", "new", "this", "import", "export", "from", "async", "await", "try", "catch", "throw", "true", "false", "null", "undefined", "typeof", "interface", "type", "enum", "implements", "readonly", "public", "private", "protected", "as", "of", "keyof"],
        .python: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import", "from", "as", "try", "except", "finally", "with", "lambda", "yield", "pass", "break", "continue", "True", "False", "None", "self", "async", "await", "raise"],
        .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "map", "nil", "true", "false", "select"],
        .rust: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "return", "if", "else", "for", "while", "loop", "match", "in", "self", "Self", "true", "false", "async", "await", "where", "dyn", "ref", "move", "crate"],
        .ruby: ["def", "end", "class", "module", "return", "if", "elsif", "else", "unless", "while", "do", "yield", "begin", "rescue", "ensure", "self", "true", "false", "nil", "require", "attr_accessor", "defmodule", "defp", "fn"],
        .java: ["public", "private", "protected", "static", "final", "class", "interface", "extends", "implements", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "new", "this", "import", "package", "try", "catch", "throw", "throws", "void", "int", "boolean", "true", "false", "null", "val", "var", "fun", "when", "object", "override", "async", "await", "late", "def"],
        .c: ["int", "char", "void", "float", "double", "long", "short", "unsigned", "signed", "const", "static", "struct", "union", "enum", "typedef", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "goto", "sizeof", "include", "define", "class", "public", "private", "protected", "virtual", "namespace", "using", "template", "new", "delete", "this", "true", "false", "nullptr", "NULL", "auto", "bool", "self", "nil", "YES", "NO", "var", "string", "async", "await", "fn"],
        .php: ["function", "return", "if", "else", "elseif", "foreach", "for", "while", "as", "class", "public", "private", "protected", "static", "new", "use", "namespace", "echo", "true", "false", "null", "array", "try", "catch", "throw", "extends", "implements", "fn", "match"],
        .sql: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP", "LIMIT", "PRIMARY", "KEY", "REFERENCES",
               "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "join", "left", "right", "inner", "on", "and", "or", "not", "null", "as", "order", "by", "group", "limit", "primary", "key", "references"],
        .lua: ["local", "function", "end", "if", "then", "else", "elseif", "for", "in", "do", "while", "repeat", "until", "return", "nil", "true", "false", "and", "or", "not"],
        .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "exit", "local", "export", "set"],
        .toml: ["true", "false"],
    ]

    var quoteCharacters: Set<Character> {
        switch self {
        case .markdown, .yaml: []
        case .markup, .css: ["\"", "'"]
        default: ["\"", "'", "`"]
        }
    }
}

public struct SyntaxToken: Hashable, Sendable {
    public enum Kind: Sendable { case keyword, string, comment, number, plain }
    public let kind: Kind
    public let range: Range<String.Index>
    public init(kind: Kind, range: Range<String.Index>) { self.kind = kind; self.range = range }
}

/// Single-line tokenizer: comments, quoted strings, numbers and keywords. Good enough for diff lines;
/// multi-line constructs (block comments, triple quotes) are not tracked across lines.
public enum SyntaxHighlighter {
    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        if language == .other { return [SyntaxToken(kind: .plain, range: text.startIndex..<text.endIndex)] }

        var tokens: [SyntaxToken] = []
        var plainStart = text.startIndex
        var i = text.startIndex

        func closePlain(upTo end: String.Index) {
            if plainStart < end { tokens.append(SyntaxToken(kind: .plain, range: plainStart..<end)) }
        }
        func emit(_ kind: SyntaxToken.Kind, _ range: Range<String.Index>) {
            closePlain(upTo: range.lowerBound)
            tokens.append(SyntaxToken(kind: kind, range: range))
            plainStart = range.upperBound
            i = range.upperBound
        }

        while i < text.endIndex {
            let c = text[i]
            if let lc = language.lineComment, text[i...].hasPrefix(lc) {
                emit(.comment, i..<text.endIndex)
                break
            }
            if language.quoteCharacters.contains(c) {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != c {
                    if text[j] == "\\" { j = text.index(after: j) }
                    if j < text.endIndex { j = text.index(after: j) }
                }
                let end = j < text.endIndex ? text.index(after: j) : text.endIndex
                emit(.string, i..<end)
                continue
            }
            let prevIsWord = i > text.startIndex && isWord(text[text.index(before: i)])
            if c.isNumber, !prevIsWord {
                var j = i
                while j < text.endIndex, text[j].isNumber || text[j] == "." || text[j] == "_" { j = text.index(after: j) }
                emit(.number, i..<j)
                continue
            }
            if isWord(c), !prevIsWord {
                var j = i
                while j < text.endIndex, isWord(text[j]) { j = text.index(after: j) }
                if language.keywords.contains(String(text[i..<j])) {
                    emit(.keyword, i..<j)
                } else {
                    i = j
                }
                continue
            }
            i = text.index(after: i)
        }
        closePlain(upTo: text.endIndex)
        return tokens
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
}
