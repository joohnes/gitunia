import Foundation

extension RepositoryStore {
    /// `git rm -r` for `paths` (files or folders, repo-relative): `keepOnDisk` stops tracking only
    /// (`--cached`), otherwise the files are deleted too. With `ignore`, each path is also added to
    /// `.gitignore` so an untracked copy doesn't show right back up. Only stages the removal — the
    /// human commits. Deleting without `-f` on purpose: git refuses files with uncommitted edits,
    /// which is the only copy of that work; `--cached` keeps the file, so `-f` loses nothing there.
    public func removeFromGit(_ paths: [String], keepOnDisk: Bool, ignore: Bool) async -> GitError? {
        let clean = paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        // Before `git rm`: a deleted folder can no longer be told apart from a file.
        let patterns = clean.map { path -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path, isDirectory: &isDir)
            return isDir.boolValue ? GitignorePattern.folder(path) : GitignorePattern.file(path)
        }
        let args = ["rm", "-r", "-q"] + (keepOnDisk ? ["--cached", "-f"] : []) + ["--"] + clean
        if let failure = await exec(args, literalPathspecs: true, recordError: false, then: { $0.failure }) {
            return failure
        }
        if ignore {
            for pattern in patterns { await addToGitignore(pattern) }
            if let e = lastError { return e }
        }
        return nil
    }

    /// Every tracked file plus every folder containing one (folders with a trailing `/`), for the
    /// ⌘K "Remove from Git…" picker.
    public func trackedPaths() async -> [String] {
        guard let out = try? await git.run(["ls-files", "-z"], in: url) else { return [] }
        return TrackedPaths.withFolders(out.split(separator: "\0").map(String.init))
    }
}

public enum TrackedPaths {
    /// `files` plus each distinct parent folder (`a/b/`), folders first, then files, each sorted.
    public static func withFolders(_ files: [String]) -> [String] {
        var folders = Set<String>()
        for file in files {
            var parts = file.split(separator: "/").dropLast()
            while !parts.isEmpty {
                guard folders.insert(parts.joined(separator: "/") + "/").inserted else { break }
                parts = parts.dropLast()
            }
        }
        return folders.sorted() + files.sorted()
    }
}
