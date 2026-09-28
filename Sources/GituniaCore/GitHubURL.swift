import Foundation

public enum GitHubURL {
    /// `https://github.com/<owner>/<repo>/pull/<n>` from an origin URL in https
    /// (`https://[user@]github.com/o/r[.git]`), scp-ssh (`git@github.com:o/r.git`) or
    /// `ssh://git@github.com/o/r.git` form; nil for anything not on github.com.
    public static func pull(remoteURL: String, number: Int) -> URL? {
        var s = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) { s = String(s[s.index(after: at)...]) }
        guard s.hasPrefix("github.com/") || s.hasPrefix("github.com:") else { return nil }
        var path = String(s.dropFirst("github.com/".count))
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/pull/\(number)")
    }
}
