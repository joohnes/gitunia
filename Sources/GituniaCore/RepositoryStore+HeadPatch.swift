import Foundation

extension RepositoryStore {
    /// HEAD's patch, in the `%H%x1f%s` + `-p` shape `SecretScanner.findings(inLog:)` expects —
    /// for `CommitBox`'s amend scan, which has nothing staged to diff when the commit's content
    /// is unchanged. Capped like `unpushedSecretFindings`: past 8 MB the scan is skipped rather
    /// than block on a huge patch. ponytail: silently skips instead of surfacing "too large",
    /// add a marker finding if that turns out to matter for amend specifically.
    public func headPatch() async -> String {
        guard let data = try? await git.runData(["show", "-p", "--format=%H%x1f%s", "HEAD"], in: url) else { return "" }
        guard data.count <= 8 * 1024 * 1024 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
