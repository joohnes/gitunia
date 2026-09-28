import Foundation

/// What `git sparse-checkout list` reports. In cone mode `patterns` are the included directories
/// (`a`, `b/c`); otherwise they're raw gitignore-style patterns.
public struct SparseState: Equatable, Sendable {
    public var enabled: Bool
    public var cone: Bool
    public var patterns: [String]
    public init(enabled: Bool, cone: Bool, patterns: [String]) {
        self.enabled = enabled; self.cone = cone; self.patterns = patterns
    }
    public static let off = SparseState(enabled: false, cone: false, patterns: [])

    /// The directories a non-cone pattern list names, when every pattern is a plain directory
    /// (`/a/`, `a/`, `b/c`) — so it can be re-set in cone mode. `nil` when any pattern uses globs,
    /// negation or anything else cone mode can't express.
    public static func coneDirectories(fromPatterns patterns: [String]) -> [String]? {
        var dirs: [String] = []
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces)
            // `/*` + `!/*/` = "root files only", which cone mode always implies.
            if p.isEmpty || p.hasPrefix("#") || p == "/*" || p == "!/*/" { continue }
            guard !p.contains(where: { "*?[]!\\".contains($0) }) else { return nil }
            let dir = p.split(separator: "/").joined(separator: "/")
            guard !dir.isEmpty else { return nil }
            dirs.append(dir)
        }
        return dirs
    }
}

extension RepositoryStore {
    /// `git sparse-checkout list` — exit 128 ("this worktree is not sparse") means off.
    /// Cone mode comes from `core.sparseCheckoutCone`.
    public func sparseState() async -> SparseState {
        guard let out = try? await git.run(["sparse-checkout", "list"], in: url) else { return .off }
        let cone = (try? await git.run(["config", "--get", "core.sparseCheckoutCone"], in: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let patterns = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return SparseState(enabled: true, cone: cone, patterns: patterns)
    }

    /// Directory names directly under `ref` — a commit (`HEAD`) or a tree (`HEAD:b/c`). Read from
    /// the object database, so folders excluded from the sparse checkout are still listed.
    /// Empty for an unborn HEAD or a missing path.
    public func topLevelDirectories(at ref: String = "HEAD") async -> [String] {
        guard let out = try? await git.run(["ls-tree", "-d", "-z", "--name-only", ref], in: url) else { return [] }
        return out.split(separator: "\0").map(String.init)
    }

    /// `git sparse-checkout set --cone <dirs…>`; no dirs keeps only the root files.
    public func setSparse(_ dirs: [String]) async -> GitError? {
        await runSparse(["set", "--cone", "--end-of-options"] + dirs)
    }

    /// `git sparse-checkout disable`: every file comes back on disk.
    public func disableSparse() async -> GitError? {
        await runSparse(["disable"])
    }

    private func runSparse(_ args: [String]) async -> GitError? {
        if let op = operation {
            return GitError(args: ["sparse-checkout"] + args, exitCode: -1,
                            stderr: "A \(op.label) is in progress — finish or abort it before changing the sparse checkout.")
        }
        return await attempt(["sparse-checkout"] + args)
    }
}
