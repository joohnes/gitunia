import Foundation

/// One configured remote, as `git remote -v` reports it. URLs are stored raw (they're needed to
/// pre-fill "Change URL…"); anything that *displays* one goes through `URLRedaction.redact`.
public struct RemoteInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public var fetchURL: String
    public var pushURL: String
    public var id: String { name }
    public init(name: String, fetchURL: String, pushURL: String) {
        self.name = name; self.fetchURL = fetchURL; self.pushURL = pushURL
    }
}

/// Parses `git remote -v`: `<name>\t<url> (fetch)` / `<name>\t<url> (push)`, in `git remote` order.
public enum RemoteListParser {
    public static func parse(_ text: String) -> [RemoteInfo] {
        var result: [RemoteInfo] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            var rest = String(parts[1])
            let isPush: Bool
            if rest.hasSuffix(" (push)") { isPush = true; rest.removeLast(" (push)".count) }
            else if rest.hasSuffix(" (fetch)") { isPush = false; rest.removeLast(" (fetch)".count) }
            else { continue }
            if let i = result.firstIndex(where: { $0.name == name }) {
                if isPush { result[i].pushURL = rest } else { result[i].fetchURL = rest }
            } else {
                result.append(RemoteInfo(name: name, fetchURL: rest, pushURL: rest))
            }
        }
        return result
    }
}

/// Remote URLs can carry credentials (`https://user:token@host/…`). Everything the app displays —
/// the Remotes sheet, toasts, `GitError` args/stderr — goes through here first.
///
/// Rule: a `scheme://userinfo@` password is replaced by `•••`. For http(s), a username with no
/// password is redacted too — `https://<token>@github.com/…` is the common token-as-username form.
/// Other schemes (`ssh://git@host`) keep their username; scp-style `git@host:path` has no secret.
public enum URLRedaction {
    public static let mask = "•••"
    private static let pattern = try! NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9+.-]*)://([^/\\s]+)@")

    public static func redact(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let scheme = ns.substring(with: m.range(at: 1)).lowercased()
            let userinfo = ns.substring(with: m.range(at: 2))
            let replacement: String
            if let colon = userinfo.firstIndex(of: ":") {
                replacement = String(userinfo[..<colon]) + ":" + mask
            } else if scheme == "http" || scheme == "https" {
                replacement = mask
            } else {
                continue
            }
            out = (out as NSString).replacingCharacters(in: m.range(at: 2), with: replacement)
        }
        return out
    }
}

/// Pure checks that don't need git. `RepositoryStore.validateRemoteName` adds git's own
/// `check-ref-format` test on top.
public enum RemoteValidation {
    public static func nameProblem(_ name: String, existing: [String]) -> String? {
        if name.isEmpty { return "Remote name can't be empty" }
        if name.hasPrefix("-") { return "A remote name can't start with \"-\"" }
        if existing.contains(name) { return "A remote named \"\(name)\" already exists" }
        return nil
    }

    public static func urlProblem(_ url: String) -> String? {
        if url.isEmpty { return "URL can't be empty" }
        if url.hasPrefix("-") { return "A URL can't start with \"-\"" }
        if url.contains(where: \.isNewline) { return "A URL can't contain line breaks" }
        return nil
    }
}

/// Which remote a first push (`push -u <remote> HEAD`) goes to: the repo's default remote if it
/// still exists, else "origin", else the first one. With no default set this is exactly the old
/// hardcoded behaviour.
public enum RemoteSelection {
    public static func pushRemote(from remotes: [String], preferred: String?) -> String? {
        if let preferred, remotes.contains(preferred) { return preferred }
        return remotes.first(where: { $0 == "origin" }) ?? remotes.first
    }

    /// `"origin/feat/x"` → `"origin"`, matching the longest known remote name (remote names may
    /// contain "/"), falling back to the first path component.
    public static func remote(ofTrackingBranch name: String, remotes: [String]) -> String {
        remotes.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            ?? name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name
    }
}

/// What `git remote remove <name>` will take with it — shown in its confirmation.
public struct RemoteRemovalImpact: Equatable, Sendable {
    /// Number of `refs/remotes/<name>/…` refs (excluding the `HEAD` symref) deleted locally.
    public let trackingRefCount: Int
    /// Local branches whose upstream is on this remote — they lose their upstream.
    public let trackingBranches: [String]

    /// Parses `for-each-ref --format=%(refname)%09%(upstream:remotename) refs/heads refs/remotes/<name>/`.
    public static func parse(_ text: String, remote: String) -> RemoteRemovalImpact {
        var count = 0
        var branches: [String] = []
        let remotePrefix = "refs/remotes/\(remote)/"
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let ref = String(parts[0])
            if ref.hasPrefix(remotePrefix) {
                if ref != remotePrefix + "HEAD" { count += 1 }
            } else if ref.hasPrefix("refs/heads/"), parts.count > 1, parts[1] == remote {
                branches.append(String(ref.dropFirst("refs/heads/".count)))
            }
        }
        return RemoteRemovalImpact(trackingRefCount: count, trackingBranches: branches)
    }
}

public enum RemoteEditResult: Equatable, Sendable {
    case succeeded
    /// Rejected before git ran (bad/duplicate name, empty URL, …).
    case invalid(String)
    /// Git itself refused; message is git's (already redacted) stderr.
    case failed(String)
}
