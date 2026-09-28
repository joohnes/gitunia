import Foundation

/// Parses `git for-each-ref --format=%(refname)%09%(HEAD) refs/heads refs/remotes`.
public enum BranchParser {
    public static func parse(_ text: String) -> [BranchInfo] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let ref = String(parts[0])
            let isCurrent = parts.count > 1 && parts[1].trimmingCharacters(in: .whitespaces) == "*"
            if ref.hasPrefix("refs/heads/") {
                return BranchInfo(name: String(ref.dropFirst("refs/heads/".count)), isCurrent: isCurrent, isRemote: false)
            }
            if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst("refs/remotes/".count))
                guard !name.hasSuffix("/HEAD") else { return nil }
                return BranchInfo(name: name, isCurrent: false, isRemote: true)
            }
            return nil
        }
    }
}
