import Foundation

/// Parses `git status --porcelain=v2 --branch` output.
public enum StatusParser {
    public static func parse(_ text: String) -> StatusResult {
        var result = StatusResult()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.oid ") {
                result.headOID = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.head ") {
                result.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    result.ahead = Int(parts[0].dropFirst()) ?? 0   // "+2"
                    result.behind = Int(parts[1].dropFirst()) ?? 0  // "-1"
                }
            } else if line.hasPrefix("1 ") {
                result.changes += parseOrdinary(line)
            } else if line.hasPrefix("2 ") {
                result.changes += parseRename(line)
            } else if line.hasPrefix("? ") {
                let path = GitQuotedPath.decode(String(line.dropFirst(2)))
                result.changes.append(FileChange(path: path, status: .untracked, area: .unstaged))
            } else if line.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let path = GitQuotedPath.decode(nthFieldToEnd(line, field: 10))
                result.changes.append(FileChange(path: path, status: .conflicted, area: .unstaged))
            }
        }
        return result
    }

    /// `# branch.upstream` (`origin/main`, the same short name `rev-parse --abbrev-ref @{upstream}`
    /// prints), or nil. Still present when the upstream ref is gone — only `# branch.ab` drops then.
    /// ponytail: separate from `parse` until `StatusResult` (Models.swift) grows an `upstream` field.
    public static func upstream(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("# ") else { return nil } // headers come first
            if line.hasPrefix("# branch.upstream ") { return String(line.dropFirst("# branch.upstream ".count)) }
        }
        return nil
    }

    // 1 XY sub mH mI mW hH hI path
    private static func parseOrdinary(_ line: String) -> [FileChange] {
        let xy = Array(nthField(line, 1))
        guard xy.count >= 2 else { return [] }
        let path = GitQuotedPath.decode(nthFieldToEnd(line, field: 8))
        return changes(x: xy[0], y: xy[1], path: path, oldPath: nil)
    }

    // 2 XY sub mH mI mW hH hI Xscore path<TAB>origPath
    private static func parseRename(_ line: String) -> [FileChange] {
        let xy = Array(nthField(line, 1))
        guard xy.count >= 2 else { return [] }
        let tail = nthFieldToEnd(line, field: 9)
        let paths = tail.split(separator: "\t", maxSplits: 1).map(String.init)
        let path = GitQuotedPath.decode(paths.first ?? tail)
        let old = paths.count > 1 ? GitQuotedPath.decode(paths[1]) : nil
        return changes(x: xy[0], y: xy[1], path: path, oldPath: old)
    }

    private static func changes(x: Character, y: Character, path: String, oldPath: String?) -> [FileChange] {
        var out: [FileChange] = []
        if let s = status(for: x) { out.append(FileChange(path: path, oldPath: oldPath, status: s, area: .staged)) }
        if let s = status(for: y) { out.append(FileChange(path: path, oldPath: oldPath, status: s, area: .unstaged)) }
        return out
    }

    private static func status(for c: Character) -> FileChange.Status? {
        switch c {
        case "M", "T": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        case "U": return .conflicted
        default: return nil
        }
    }

    private static func nthField(_ line: String, _ n: Int) -> Substring {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard n >= 0, n < fields.count else { return "" }
        return fields[n]
    }

    /// Everything from field `field` (0-based, space separated) to end of line, preserving spaces in paths.
    private static func nthFieldToEnd(_ line: String, field: Int) -> String {
        var idx = line.startIndex
        var seen = 0
        while seen < field, let sp = line[idx...].firstIndex(of: " ") {
            idx = line.index(after: sp)
            seen += 1
        }
        return String(line[idx...])
    }
}
