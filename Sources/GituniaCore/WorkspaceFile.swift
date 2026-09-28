import Foundation

/// A saved workspace: single repositories plus linked folders that are scanned live (see
/// `WorkspaceMembership`). In memory every path is absolute and standardized; relative paths exist
/// only on disk, so "Save As" to a new location is just `save(to:)` there.
public struct WorkspaceFile: Equatable, Sendable {
    public struct Folder: Equatable, Sendable {
        public var path: String
        /// Repos removed from the workspace, relative to `path` — a live scan would re-add them otherwise.
        public var excluded: [String]
        public init(path: String, excluded: [String] = []) { self.path = path; self.excluded = excluded }
    }

    public var repositories: [String]
    public var folders: [Folder]
    /// Keyed by repo path: a repo found in a linked folder has no entry of its own to hold them.
    public var tags: [String: [String]]

    public static let fileExtension = "gitunia-workspace"

    public init(repositories: [String] = [], folders: [Folder] = [], tags: [String: [String]] = [:]) {
        self.repositories = repositories; self.folders = folders; self.tags = tags
    }

    public var isEmpty: Bool { repositories.isEmpty && folders.isEmpty }

    private struct Disk: Codable {
        struct DiskFolder: Codable { var path: String; var excluded: [String]? }
        var version: Int?
        var repositories: [String]?
        var folders: [DiskFolder]?
        var tags: [String: [String]]?
    }

    public static func load(from url: URL) throws -> WorkspaceFile {
        let disk = try JSONDecoder().decode(Disk.self, from: Data(contentsOf: url))
        let base = url.deletingLastPathComponent()
        return WorkspaceFile(
            repositories: (disk.repositories ?? []).map { resolve($0, relativeTo: base) },
            folders: (disk.folders ?? []).map { Folder(path: resolve($0.path, relativeTo: base), excluded: $0.excluded ?? []) },
            tags: Dictionary((disk.tags ?? [:]).map { (resolve($0.key, relativeTo: base), $0.value) }, uniquingKeysWith: { a, _ in a })
        )
    }

    public func save(to url: URL, relativePaths: Bool = true) throws {
        let base = url.deletingLastPathComponent()
        let out: (String) -> String = { relativePaths ? Self.relativize($0, to: base) : Self.standardize($0) }
        let disk = Disk(
            version: 1,
            repositories: repositories.map(out),
            folders: folders.map { Disk.DiskFolder(path: out($0.path), excluded: $0.excluded) },
            tags: Dictionary(tags.map { (out($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(disk).write(to: url, options: .atomic)
    }

    public static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    public static func resolve(_ stored: String, relativeTo baseDirectory: URL) -> String {
        if stored.hasPrefix("/") || stored.hasPrefix("~") { return standardize(stored) }
        return baseDirectory.appendingPathComponent(stored).standardizedFileURL.path
    }

    /// Relative to `baseDirectory`, except across volumes, where a relative path would not survive
    /// moving the file anyway.
    public static func relativize(_ absolute: String, to baseDirectory: URL) -> String {
        let target = URL(fileURLWithPath: standardize(absolute))
        let base = baseDirectory.standardizedFileURL
        if let a = volume(of: target), let b = volume(of: base), !a.isEqual(b) { return target.path }
        let t = target.pathComponents, b = base.pathComponents
        var common = 0
        while common < t.count, common < b.count, t[common] == b[common] { common += 1 }
        let parts = Array(repeating: "..", count: b.count - common) + t[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Nearest existing ancestor's volume — the path itself may not exist (a missing repo).
    private static func volume(of url: URL) -> NSObject? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
    }
}
