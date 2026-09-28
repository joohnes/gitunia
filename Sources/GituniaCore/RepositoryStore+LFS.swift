import Foundation

extension RepositoryStore {
    /// `git lfs version` result, once per app run — `nil` until `checkLFSInstalled()` has run.
    private static var lfsInstalledCache: Bool?

    public var lfsInstalled: Bool? { Self.lfsInstalledCache }

    public func checkLFSInstalled() async -> Bool {
        if let override = lfsPathOverride {
            return (try? await git.runCombined(["lfs", "version"], in: url, extraEnvironment: Self.path(prepending: override))) != nil
        }
        if let cached = Self.lfsInstalledCache { return cached }
        let ok = (try? await git.run(["lfs", "version"], in: url)) != nil
        Self.lfsInstalledCache = ok
        return ok
    }

    private static func path(prepending dir: String) -> [String: String] {
        ["PATH": dir + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")]
    }

    /// A stat per `refreshStatus()`; the file is only read (off the main actor) when its mtime moved.
    func refreshAttributeRules() async {
        let file = url.appendingPathComponent(".gitattributes")
        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard mtime != attributesMTime else { return }
        attributesMTime = mtime
        let rules = await Task.detached { GitAttributes.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "") }.value
        if rules != attributeRules { attributeRules = rules }
    }

    /// `git lfs track <pattern>` — appends to `.gitattributes`; staging it is the caller's call.
    public func lfsTrack(_ pattern: String) async -> GitError? {
        let args = ["lfs", "track", pattern]
        guard await checkLFSInstalled() else { return GitError(args: args, exitCode: -1, stderr: "Git LFS is not installed") }
        return await attempt(args, env: lfsPathOverride.map(Self.path(prepending:)) ?? [:])
    }
}
