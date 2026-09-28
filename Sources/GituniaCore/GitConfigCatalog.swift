import Foundation

/// The handful of git config keys whose per-repository differences cause surprises — what
/// `GitConfigSheet` lists. Deliberately not a generic config editor.
public enum GitConfigCatalog {
    public struct ConfigKey: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case bool
            case choice([String])
            case text
        }

        public let key: String
        public let title: String
        public let explanation: String
        public let kind: Kind
        public let group: String
        public var id: String { key }
    }

    public static let groups = ["Identity", "Pull & push", "Rebase & merge", "Signing", "Misc"]

    public static let keys: [ConfigKey] = [
        ConfigKey(key: "user.name", title: "Name", explanation: "The author name recorded on commits you make here.", kind: .text, group: "Identity"),
        ConfigKey(key: "user.email", title: "Email", explanation: "The author email recorded on commits — hosts use it to link commits to your account.", kind: .text, group: "Identity"),

        ConfigKey(key: "pull.rebase", title: "Pull rebases", explanation: "Whether `git pull` rebases your local commits on top of the remote instead of creating a merge commit.",
                  kind: .choice(["false", "true", "merges", "interactive"]), group: "Pull & push"),
        ConfigKey(key: "push.default", title: "Push default", explanation: "Which branch `git push` sends when you don't name one. `simple` refuses if the upstream has a different name — that's the safe default.",
                  kind: .choice(["simple", "current", "upstream", "matching", "nothing"]), group: "Pull & push"),
        ConfigKey(key: "push.autoSetupRemote", title: "Auto set upstream on push", explanation: "Whether the first push of a new branch sets its upstream automatically, as if you'd passed `-u`.",
                  kind: .bool, group: "Pull & push"),
        ConfigKey(key: "branch.autoSetupMerge", title: "Track on branch creation", explanation: "Whether a branch created from another branch gets that branch as its upstream.",
                  kind: .choice(["false", "true", "always", "inherit", "simple"]), group: "Pull & push"),
        ConfigKey(key: "fetch.prune", title: "Prune on fetch", explanation: "Whether fetching deletes remote-tracking branches that no longer exist on the remote.",
                  kind: .bool, group: "Pull & push"),

        ConfigKey(key: "rebase.autoStash", title: "Auto-stash on rebase", explanation: "Whether a rebase stashes your uncommitted changes first and restores them afterwards, instead of refusing.",
                  kind: .bool, group: "Rebase & merge"),
        ConfigKey(key: "rebase.updateRefs", title: "Update stacked branches", explanation: "Whether rebasing a branch also moves other branches that point into the rewritten commits.",
                  kind: .bool, group: "Rebase & merge"),
        ConfigKey(key: "merge.conflictStyle", title: "Conflict style", explanation: "How conflict markers look: `diff3`/`zdiff3` also show the original text both sides started from.",
                  kind: .choice(["merge", "diff3", "zdiff3"]), group: "Rebase & merge"),

        ConfigKey(key: "commit.gpgsign", title: "Sign commits", explanation: "Whether every commit is cryptographically signed — commits fail if the key isn't available.",
                  kind: .bool, group: "Signing"),
        ConfigKey(key: "gpg.format", title: "Signature format", explanation: "Which tool signs: `openpgp` uses gpg, `ssh` uses an SSH key, `x509` uses a certificate.",
                  kind: .choice(["openpgp", "ssh", "x509"]), group: "Signing"),

        ConfigKey(key: "core.hooksPath", title: "Hooks folder", explanation: "Where git looks for hooks instead of `.git/hooks` — often set by tools like Husky.",
                  kind: .text, group: "Misc"),
        ConfigKey(key: "core.autocrlf", title: "Line-ending conversion", explanation: "Whether git converts line endings on checkout and commit; `input` only converts CRLF to LF when committing.",
                  kind: .choice(["false", "true", "input"]), group: "Misc"),
        ConfigKey(key: "init.defaultBranch", title: "Default branch name", explanation: "The name of the first branch in new repositories — only matters for `git init`.",
                  kind: .text, group: "Misc"),
    ]
}
