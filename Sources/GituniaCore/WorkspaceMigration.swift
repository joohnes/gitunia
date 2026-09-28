import Foundation

/// The one-time move from "workspace = a scanned folder" to workspace files: the old folder
/// becomes a linked folder in an untitled workspace, and its repos' tags move into that file
/// (tags now belong to a workspace; every other per-repo pref stays global).
public enum WorkspaceMigration {
    public static func migrate(_ config: WorkspaceConfig) -> (config: WorkspaceConfig, file: WorkspaceFile)? {
        // Keyed on `workspacePath` alone (cleared only by a successful migration): a failed attempt
        // still lets that launch save its windows, and the next launch must retry.
        guard let saved = config.workspacePath else { return nil }
        let folder = WorkspaceFile.standardize(saved)
        var out = config
        out.workspacePath = nil
        var file = WorkspaceFile(folders: [.init(path: folder)])
        for (path, prefs) in config.repos where (path == folder || path.hasPrefix(folder + "/")) && !prefs.tags.isEmpty {
            file.setTags(prefs.tags, for: path)
            out.repos[path]?.tags = []
        }
        return (out, file)
    }
}
