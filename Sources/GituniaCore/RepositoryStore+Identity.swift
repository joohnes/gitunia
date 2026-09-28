import Foundation

/// Who a commit in this repository would be authored as, and whether it would be signed —
/// the effective (system + global + local) config, as git itself resolves it.
public struct CommitIdentity: Sendable, Equatable {
    public var name: String?
    public var email: String?
    public var signingEnabled: Bool
    /// `gpg.format`: `"openpgp"` (git's default when unset), `"ssh"` or `"x509"`.
    public var signingFormat: String?
    public var signingKey: String?

    public init(name: String? = nil, email: String? = nil, signingEnabled: Bool = false,
                signingFormat: String? = nil, signingKey: String? = nil) {
        self.name = name
        self.email = email
        self.signingEnabled = signingEnabled
        self.signingFormat = signingFormat
        self.signingKey = signingKey
    }
}

extension RepositoryStore {
    /// One `git config --get-regexp` call; exit 1 just means none of the keys are set.
    public func commitIdentity() async -> CommitIdentity {
        let out = (try? await git.run(["config", "--get-regexp", #"^(user\.(name|email)|commit\.gpgsign|gpg\.format|user\.signingkey)$"#],
                                      in: url, allowedExitCodes: [0, 1])) ?? ""
        return Self.parseIdentity(out)
    }

    /// Not part of `refreshStatus()` (same cost reasoning as `stashCount`): loaded on repo
    /// selection and re-read right before each commit's pre-commit scan.
    public func refreshIdentity() async {
        let id = await commitIdentity()
        if id != identity { identity = id }
    }

    /// `<key> <value>` per line, keys lowercased by git, later lines (more local scopes) win.
    /// A key with no value (`[commit] gpgsign`) is printed bare and means `true`.
    public nonisolated static func parseIdentity(_ output: String) -> CommitIdentity {
        var id = CommitIdentity()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            let value = parts.count > 1 ? String(parts[1]) : nil
            switch parts.first.map(String.init) {
            case "user.name": id.name = value
            case "user.email": id.email = value
            case "user.signingkey": id.signingKey = value
            case "gpg.format": id.signingFormat = value
            case "commit.gpgsign": id.signingEnabled = ["true", "yes", "on", "1", nil].contains(value?.lowercased())
            default: break
            }
        }
        return id
    }
}

public enum SigningFailure {
    private static let markers = ["gpg failed", "error: gpg", "signing failed", "ssh-keygen"]

    /// A plain-language next step when a commit's stderr looks like a signing failure.
    public static func hint(stderr: String) -> String? {
        let lower = stderr.lowercased()
        guard markers.contains(where: lower.contains) else { return nil }
        return "Signing failed — check gpg.format / user.signingkey, or disable commit.gpgsign for this repository"
    }
}
