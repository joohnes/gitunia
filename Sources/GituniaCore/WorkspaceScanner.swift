import Foundation

public enum WorkspaceScanner {
    public static let skippedDirectoryNames: Set<String> = ["node_modules", ".build", "DerivedData", "Pods", "vendor"]

    /// Finds git repositories under `root`, at most `maxDepth` levels down.
    /// Does not descend into a found repository, hidden directories, or `skippedDirectoryNames`.
    public static func findRepositories(in root: URL, maxDepth: Int = 3) -> [URL] {
        var out: [URL] = []
        scan(root.standardizedFileURL, depth: 0, maxDepth: maxDepth, into: &out)
        let seen = Set(out.map { $0.resolvingSymlinksInPath().path })
        out += linkedWorktrees(of: out, inside: root.standardizedFileURL).filter { !seen.contains($0.path) }
        return out.sorted { $0.path < $1.path }
    }

    private static func scan(_ dir: URL, depth: Int, maxDepth: Int, into out: inout [URL]) {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            out.append(dir)
            return
        }
        guard depth < maxDepth,
              let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || skippedDirectoryNames.contains(name) { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            scan(child, depth: depth + 1, maxDepth: maxDepth, into: &out)
        }
    }
}
