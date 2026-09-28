import Foundation

/// Which repositories a workspace file stands for, given what the linked folders' scans found.
/// Pure so the rules (dedup, exclusion, missing) are testable without a disk.
public enum WorkspaceMembership {
    public enum Source: Equatable, Sendable { case single, folder(String) }

    public struct Entry: Equatable, Sendable {
        public let path: String
        public let source: Source
        public init(path: String, source: Source) { self.path = path; self.source = source }
    }

    public struct Result: Equatable, Sendable {
        public var present: [Entry] = []
        public var missing: [String] = []
        public var missingFolders: [String] = []
    }

    /// `scans[folderPath]` = repos found in that folder; no entry = folder was not scanned (treated as missing).
    public static func resolve(_ file: WorkspaceFile, scans: [String: [String]], exists: (String) -> Bool) -> Result {
        var result = Result()
        var seen = Set<String>()
        for path in file.repositories where seen.insert(path).inserted {
            if exists(path) { result.present.append(Entry(path: path, source: .single)) } else { result.missing.append(path) }
        }
        for folder in file.folders {
            guard let found = scans[folder.path] else { result.missingFolders.append(folder.path); continue }
            let excluded = Set(folder.excluded)
            for path in found where !excluded.contains(relative(path, in: folder.path)) && seen.insert(path).inserted {
                result.present.append(Entry(path: path, source: .folder(folder.path)))
            }
        }
        return result
    }

    /// `path` relative to `folder`; "." when `path` is the folder itself (a migrated workspace
    /// folder can be a repo), so an exclusion is never stored as an absolute path.
    public static func relative(_ path: String, in folder: String) -> String {
        if path == folder { return "." }
        return path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
    }

    /// Inverse of `relative`.
    public static func absolute(_ relative: String, in folder: String) -> String {
        relative == "." ? folder : folder + "/" + relative
    }

    /// Whether a scan of `folder` can find `path` (the folder itself included).
    static func covers(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }
}

/// What `WorkspaceFile.remove` did, so the Undo toast can reverse exactly that.
public enum WorkspaceRemoval: Equatable, Sendable {
    /// `excludedIn`: linked folders that also cover the repo, which were told to exclude it too.
    case single(String, excludedIn: [String])
    /// `folders`: every linked folder that covers `path` and was told to exclude it — excluding it
    /// in just the one it came from would let another covering folder bring it straight back.
    case excluded(folders: [String], path: String)
}

extension WorkspaceFile {
    /// A repo inside a linked folder is un-excluded rather than added twice.
    public mutating func addRepository(_ path: String) {
        var unexcluded = false
        for i in folders.indices where WorkspaceMembership.covers(folders[i].path, path) {
            let rel = WorkspaceMembership.relative(path, in: folders[i].path)
            if folders[i].excluded.contains(rel) { folders[i].excluded.removeAll { $0 == rel }; unexcluded = true }
        }
        if !unexcluded, !repositories.contains(path) { repositories.append(path) }
    }

    public mutating func linkFolder(_ path: String) {
        if !folders.contains(where: { $0.path == path }) { folders.append(Folder(path: path)) }
    }

    public mutating func unlinkFolder(_ path: String) {
        folders.removeAll { $0.path == path }
    }

    public mutating func remove(_ entry: WorkspaceMembership.Entry) -> WorkspaceRemoval {
        switch entry.source {
        case .single:
            repositories.removeAll { $0 == entry.path }
            // A covering linked folder would otherwise bring the repo straight back on the next resolve.
            return .single(entry.path, excludedIn: exclude(entry.path))
        case .folder:
            return .excluded(folders: exclude(entry.path), path: entry.path)
        }
    }

    /// Excludes `path` in every linked folder that covers it; returns the folders that newly
    /// excluded it, so Undo reverses exactly this and no earlier exclusion.
    private mutating func exclude(_ path: String) -> [String] {
        var changed: [String] = []
        for i in folders.indices where WorkspaceMembership.covers(folders[i].path, path) {
            let rel = WorkspaceMembership.relative(path, in: folders[i].path)
            if !folders[i].excluded.contains(rel) { folders[i].excluded.append(rel); changed.append(folders[i].path) }
        }
        return changed
    }

    public mutating func undo(_ removal: WorkspaceRemoval) {
        switch removal {
        case .single(let path, let excludedIn):
            if !repositories.contains(path) { repositories.append(path) }
            restore(path, in: excludedIn)
        case .excluded(let folders, let path): restore(path, in: folders)
        }
    }

    private mutating func restore(_ path: String, in folders: [String]) {
        for folder in folders { restoreExcluded(folder: folder, relative: WorkspaceMembership.relative(path, in: folder)) }
    }

    public mutating func restoreExcluded(folder: String, relative: String) {
        guard let i = folders.firstIndex(where: { $0.path == folder }) else { return }
        folders[i].excluded.removeAll { $0 == relative }
    }

    public mutating func setTags(_ newTags: [String], for repo: String) {
        tags[repo] = newTags.isEmpty ? nil : newTags.sorted()
    }
}
