import Foundation

public enum SyntaxLanguage: Sendable, Equatable {
    case swift, javascript, python, go, rust, ruby, java, shell, json, yaml, markdown, other

    public static func from(fileExtension: String?) -> SyntaxLanguage {
        switch (fileExtension ?? "").lowercased() {
        case "swift": .swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": .javascript
        case "py": .python
        case "go": .go
        case "rs": .rust
        case "rb": .ruby
        case "java", "kt", "kts": .java
        case "sh", "zsh", "bash": .shell
        case "json": .json
        case "yml", "yaml": .yaml
        case "md", "markdown": .markdown
        default: .other
        }
    }

    var lineComment: String? {
        switch self {
        case .python, .ruby, .shell, .yaml: "#"
        case .markdown, .json, .other: nil
        default: "//"
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift: ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "async", "await", "public", "private", "internal", "static", "self", "true", "false", "nil", "init", "some", "any", "where"]
        case .javascript: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "class", "extends", "new", "this", "import", "export", "from", "async", "await", "try", "catch", "throw", "true", "false", "null", "undefined", "typeof", "interface", "type", "enum"]
        case .python: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import", "from", "as", "try", "except", "finally", "with", "lambda", "yield", "pass", "break", "continue", "True", "False", "None", "self", "async", "await", "raise"]
        case .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "map", "nil", "true", "false", "select"]
        case .rust: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "return", "if", "else", "for", "while", "loop", "match", "in", "self", "Self", "true", "false", "async", "await", "where", "dyn", "ref", "move", "crate"]
        case .ruby: ["def", "end", "class", "module", "return", "if", "elsif", "else", "unless", "while", "do", "yield", "begin", "rescue", "ensure", "self", "true", "false", "nil", "require", "attr_accessor"]
        case .java: ["public", "private", "protected", "static", "final", "class", "interface", "extends", "implements", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "new", "this", "import", "package", "try", "catch", "throw", "throws", "void", "int", "boolean", "true", "false", "null", "val", "var", "fun", "when"]
        case .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "exit", "local", "export", "set"]
        case .json, .yaml, .markdown, .other: []
        }
    }

    var quoteCharacters: Set<Character> {
        switch self {
        case .markdown, .yaml: []
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
