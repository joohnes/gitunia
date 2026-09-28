import Foundation

/// Parses unified diff output of `git diff`.
public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var path: String? = nil
        var diffHeaderLine: String? = nil
        var minusLine: String? = nil
        var plusLine: String? = nil
        var renameToLine: String? = nil
        var copyToLine: String? = nil
        var isBinary = false
        var hunks: [Hunk] = []
        var hunkHeader: String? = nil
        var lines: [DiffLine] = []
        var oldNo = 0
        var newNo = 0

        func resolvePath() -> String? {
            func stripped(_ s: String, prefix: String) -> String {
                var s = s.hasSuffix("\t") ? String(s.dropLast()) : s
                s = GitQuotedPath.decode(s) // must decode before stripping: "b/" is inside the quotes
                if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
                return s
            }
            let plusStripped = plusLine.map { $0.hasSuffix("\t") ? String($0.dropLast()) : $0 }
            if let plusLine, plusStripped != "/dev/null" {
                return stripped(plusLine, prefix: "b/")
            }
            if let minusLine, plusStripped == "/dev/null" {
                return stripped(minusLine, prefix: "a/")
            }
            // No ---/+++ lines: pure rename/copy (no content change) or a binary file. Prefer the
            // "rename to"/"copy to" line git already gives us verbatim over parsing the header.
            if let renameToLine { return GitQuotedPath.decode(renameToLine) }
            if let copyToLine { return GitQuotedPath.decode(copyToLine) }
            if let diffHeaderLine { return pathFromDiffHeader(diffHeaderLine) }
            return nil
        }
        func closeHunk() {
            if let h = hunkHeader { hunks.append(Hunk(header: h, lines: lines)) }
            hunkHeader = nil
            lines = []
        }
        func closeFile() {
            closeHunk()
            if path == nil { path = resolvePath() }
            if let p = path { files.append(FileDiff(path: p, isBinary: isBinary, hunks: hunks)) }
            path = nil; diffHeaderLine = nil; minusLine = nil; plusLine = nil
            renameToLine = nil; copyToLine = nil; isBinary = false; hunks = []
        }

        // Not `split(separator: "\n")`: Swift treats "\r\n" as one Character, so a CRLF file's
        // diff would never split. Foundation splits on the "\n" code unit, keeping "\r" in text.
        let rawLines = text.components(separatedBy: "\n")
        for (i, raw) in rawLines.enumerated() {
            let line = String(raw)
            // Trailing empty line after the final newline is not content.
            if line.isEmpty && i == rawLines.count - 1 { continue }
            if line.hasPrefix("diff --git ") {
                closeFile()
                diffHeaderLine = line
            } else if line.hasPrefix("Binary files ") {
                isBinary = true
            } else if line.hasPrefix("rename to ") {
                renameToLine = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy to ") {
                copyToLine = String(line.dropFirst("copy to ".count))
            } else if hunkHeader == nil && line.hasPrefix("--- ") {
                minusLine = String(line.dropFirst("--- ".count))
            } else if hunkHeader == nil && line.hasPrefix("+++ ") {
                plusLine = String(line.dropFirst("+++ ".count))
            } else if line.hasPrefix("@@ ") {
                if path == nil { path = resolvePath() }
                closeHunk()
                hunkHeader = line
                (oldNo, newNo) = HunkHeader(line).map { ($0.oldStart, $0.newStart) } ?? (1, 1)
            } else if hunkHeader != nil {
                if line.hasPrefix("+") {
                    lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newNo))
                    newNo += 1
                } else if line.hasPrefix("-") {
                    lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNumber: oldNo, newNumber: nil))
                    oldNo += 1
                } else if line.hasPrefix(" ") || line.isEmpty {
                    lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: oldNo, newNumber: newNo))
                    oldNo += 1; newNo += 1
                } else if line.hasPrefix("\\ No newline at end of file") {
                    if !lines.isEmpty { lines[lines.count - 1].noNewline = true }
                }
            }
        }
        closeFile()
        return files
    }

    /// "diff --git a/old b/new" → "new". Only reached when there's no ---/+++ pair and no
    /// "rename to"/"copy to" line to read the path from directly — i.e. a mode-only change or a
    /// binary diff, both of which git only emits without those lines when old == new. That means
    /// the header (once the "diff --git " prefix and, if quoted, the outer quoting is handled) is
    /// always exactly `a/P b/P` for some single path `P`, so it can be split at the midpoint
    /// instead of searching for `" b/"` as a substring, which can match *inside* P itself.
    private static func pathFromDiffHeader(_ line: String) -> String {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return line }
        let rest = line.dropFirst(prefix.count)
        if rest.hasPrefix("\""), let aClose = findClosingQuote(rest, openAt: rest.startIndex) {
            var bSide = rest[rest.index(after: aClose)...]
            if bSide.hasPrefix(" ") { bSide = bSide.dropFirst() }
            var decoded = GitQuotedPath.decode(String(bSide))
            if decoded.hasPrefix("b/") { decoded = String(decoded.dropFirst(2)) }
            return decoded
        }
        // Unquoted "a/P b/P": total length is 2 ("a/") + P.count + 3 (" b/") + P.count, so
        // P.count = (total - 5) / 2 and the b-side starts right after that.
        let total = rest.count
        if total >= 5, (total - 5).isMultiple(of: 2) {
            let pCount = (total - 5) / 2
            let bStart = rest.index(rest.startIndex, offsetBy: pCount + 5)
            return String(rest[bStart...])
        }
        if let r = rest.range(of: " b/", options: .backwards) {
            return String(rest[r.upperBound...])
        }
        return String(rest)
    }

    /// Index of the `"` that closes a C-quoted string opened at `openAt` (which must itself be a
    /// `"`), skipping backslash-escaped characters. `nil` if the string is never closed.
    private static func findClosingQuote(_ s: Substring, openAt: Substring.Index) -> Substring.Index? {
        var i = s.index(after: openAt)
        while i < s.endIndex {
            if s[i] == "\\" {
                i = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            } else if s[i] == "\"" {
                return i
            } else {
                i = s.index(after: i)
            }
        }
        return nil
    }
}
