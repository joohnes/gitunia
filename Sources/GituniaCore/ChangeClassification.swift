import Foundation

public enum ChangeClassification {
    private static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "Package.resolved",
        "Gemfile.lock", "poetry.lock", "uv.lock", "composer.lock", "go.sum", "Podfile.lock",
        "flake.lock", "bun.lockb",
    ]

    /// Generated dependency lockfiles (at any depth) — noise an agent churns, grouped away in the
    /// Changes list. Any `*.lock` counts too.
    public static func isLockfile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return lockfileNames.contains(name) || name.hasSuffix(".lock")
    }
}
