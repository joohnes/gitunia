import Foundation

/// Decodes a path the way git prints one on stdout.
///
/// Independent of `core.quotePath` (which only controls octal-escaping of non-ASCII bytes), git
/// always wraps a path in `"…"` and backslash-escapes it when it contains a control character
/// (tab, newline, ...), a literal `"`, or a literal `\`. The escapes used are `\a \b \t \n \v \f \r
/// \" \\` and `\NNN` octal byte escapes. Octal escapes encode raw *bytes*, not code points (that's
/// how a multi-byte UTF-8 sequence gets split across several `\NNN`s when quoting is byte-wise), so
/// this decodes into a byte buffer and assembles the result as UTF-8 at the end.
///
/// A path that isn't quoted (the common case — `GitRunner` passes `-c core.quotePath=false`, and
/// unquoted paths never need decoding regardless) is returned unchanged.
public enum GitQuotedPath {
    public static func decode(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let inner = Array(s.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var i = 0
        while i < inner.count {
            let c = inner[i]
            guard c == "\\", i + 1 < inner.count else {
                bytes.append(contentsOf: Array(String(c).utf8))
                i += 1
                continue
            }
            let n = inner[i + 1]
            switch n {
            case "a": bytes.append(0x07); i += 2
            case "b": bytes.append(0x08); i += 2
            case "t": bytes.append(0x09); i += 2
            case "n": bytes.append(0x0A); i += 2
            case "v": bytes.append(0x0B); i += 2
            case "f": bytes.append(0x0C); i += 2
            case "r": bytes.append(0x0D); i += 2
            case "\"": bytes.append(0x22); i += 2
            case "\\": bytes.append(0x5C); i += 2
            default:
                if let d0 = n.octalValue {
                    var value = d0
                    var count = 1
                    var j = i + 2
                    while count < 3, j < inner.count, let d = inner[j].octalValue {
                        value = value * 8 + d
                        j += 1; count += 1
                    }
                    bytes.append(UInt8(value & 0xFF))
                    i = j
                } else {
                    // Unrecognized escape: keep it literally rather than losing the backslash.
                    bytes.append(0x5C)
                    i += 1
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension Character {
    var octalValue: Int? {
        guard let ascii = asciiValue, ascii >= 0x30, ascii <= 0x37 else { return nil }
        return Int(ascii - 0x30)
    }
}
