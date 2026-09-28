import Foundation

public struct Submodule: Hashable, Sendable, Identifiable {
    public enum State: Sendable, Hashable {
        case current, uninitialized, outOfDate, conflict
    }
    public let path: String
    public let commit: String
    public let state: State
    /// `git describe`-style suffix git prints in parentheses, e.g. `heads/main`; absent when uninitialized.
    public let describe: String?
    /// `.gitmodules` `url` / `branch` for this path (filled by `refreshSubmodules`).
    public var url: String?
    public var branch: String?
    /// The gitlink the superproject's index records (`git ls-files -s`, mode 160000).
    public var recordedCommit: String?
    public var id: String { path }
    /// What's actually checked out: `commit` from `git submodule status`, except when uninitialized
    /// (git then prints the recorded commit) or conflicted (all zeros).
    public var checkedOutCommit: String? { state == .current || state == .outOfDate ? commit : nil }

    public init(path: String, commit: String, state: State, describe: String?,
                url: String? = nil, branch: String? = nil, recordedCommit: String? = nil) {
        self.path = path; self.commit = commit; self.state = state; self.describe = describe
        self.url = url; self.branch = branch; self.recordedCommit = recordedCommit
    }
}

public enum SubmoduleParser {
    /// Parses `git submodule status --recursive`. Real lines (git 2.50):
    /// ` 8ee21…7f libs/lib (heads/main)`, `+016ff…35 other (heads/main)`,
    /// `-8ee21…7f libs/lib` (fresh clone, not initialized), `U0000…00 other` (pointer conflict).
    public static func parse(_ output: String) -> [Submodule] {
        output.split(separator: "\n").compactMap { line in
            guard let flag = line.first else { return nil }
            let state: Submodule.State
            switch flag {
            case " ": state = .current
            case "-": state = .uninitialized
            case "+": state = .outOfDate
            case "U": state = .conflict
            default: return nil
            }
            let body = line.dropFirst()
            guard let space = body.firstIndex(of: " ") else { return nil }
            let commit = String(body[..<space])
            var rest = body[body.index(after: space)...]
            var describe: String?
            if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
                describe = String(rest[open.upperBound..<rest.index(before: rest.endIndex)])
                rest = rest[..<open.lowerBound]
            }
            return Submodule(path: String(rest), commit: commit, state: state, describe: describe)
        }
    }

    /// Parses `git config --file .gitmodules --list` (`submodule.<name>.<key>=<value>`; the name
    /// may itself contain dots, so the key is split at the last one) into per-path name/url/branch.
    /// The name is kept alongside path/url/branch because it — not the path — names the submodule's
    /// clone under `.git/modules/` (`submodule add --name`, or a submodule later moved/renamed).
    public static func parseGitmodules(_ output: String) -> [String: (name: String, url: String?, branch: String?)] {
        var byName: [String: [String: String]] = [:]
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("submodule."), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: "submodule.".count)..<eq]
            guard let dot = key.lastIndex(of: ".") else { continue }
            byName[String(key[..<dot]), default: [:]][String(key[key.index(after: dot)...])] = String(line[line.index(after: eq)...])
        }
        var result: [String: (name: String, url: String?, branch: String?)] = [:]
        for (name, fields) in byName {
            if let path = fields["path"] { result[path] = (name, fields["url"], fields["branch"]) }
        }
        return result
    }

    /// Parses `git ls-files -s -z` into path → recorded gitlink hash (mode 160000 entries only;
    /// during a pointer conflict the first stage listed wins).
    public static func parseRecorded(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for record in output.split(separator: "\0") {
            // `<mode> <hash> <stage>\t<path>`
            guard record.hasPrefix("160000 "), let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { continue }
            let path = String(record[record.index(after: tab)...])
            if result[path] == nil { result[path] = String(fields[1]) }
        }
        return result
    }
}

public struct Worktree: Hashable, Sendable, Identifiable {
    public let path: String
    public let head: String?
    /// Short branch name (`refs/heads/` stripped); nil when detached or bare.
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool
    /// Present (possibly empty) when locked; the text is the lock reason.
    public let lockedReason: String?
    public let prunableReason: String?
    public var id: String { path }
    public var isPrunable: Bool { prunableReason != nil }
}

public enum WorktreeParser {
    /// Parses `git worktree list --porcelain`: blank-line separated records of
    /// `worktree <path>`, `HEAD <sha>`, `branch refs/heads/x` | `detached` | `bare`,
    /// optional `locked [reason]` and `prunable [reason]` (verified against git 2.50 output).
    public static func parse(_ output: String) -> [Worktree] {
        output.components(separatedBy: "\n\n").compactMap { record in
            var path: String?, head: String?, branch: String?, locked: String?, prunable: String?
            var detached = false, bare = false
            for line in record.split(separator: "\n") {
                let (key, value) = line.firstIndex(of: " ").map { (line[..<$0], String(line[line.index(after: $0)...])) } ?? (line, "")
                switch key {
                case "worktree": path = value
                case "HEAD": head = value
                case "branch": branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
                case "detached": detached = true
                case "bare": bare = true
                case "locked": locked = value
                case "prunable": prunable = value
                default: break
                }
            }
            guard let path else { return nil }
            return Worktree(path: path, head: head, branch: branch, isDetached: detached, isBare: bare,
                            lockedReason: locked, prunableReason: prunable)
        }
    }
}
