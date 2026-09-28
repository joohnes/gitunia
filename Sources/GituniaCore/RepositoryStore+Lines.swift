import Foundation

/// Line-level staging (see `PatchBuilder.patch(path:hunks:selected:reverse:)` for the rules).
/// `diff` must be the diff the selection was made in — the one `diff(for:context:)` returned for
/// `change` — and any hunk/scope works, including a whole-file (`-U100000`) diff.
extension RepositoryStore {
    /// Whether line operations make sense for this file: a plain in-place modification (or a newly
    /// added file in the index, whose lines can be unstaged). Untracked/deleted/renamed/conflicted
    /// files would need file-creation/deletion patches — whole-file actions cover those.
    public static func supportsLineActions(_ change: FileChange) -> Bool {
        change.status == .modified || (change.status == .added && change.area == .staged)
    }

    /// `git apply --cached` of the selected lines of an unstaged diff.
    @discardableResult
    public func stageLines(_ selected: Set<DiffLineRef>, in diff: FileDiff, of change: FileChange) async -> Bool {
        await applyLines(selected, in: diff, of: change, reverse: false, args: ["apply", "--cached"])
    }

    /// `git apply --cached --reverse` of the selected lines of a staged diff.
    @discardableResult
    public func unstageLines(_ selected: Set<DiffLineRef>, in diff: FileDiff, of change: FileChange) async -> Bool {
        await applyLines(selected, in: diff, of: change, reverse: true, args: ["apply", "--cached", "--reverse"])
    }

    /// `git apply --reverse` of the selected lines of an unstaged diff onto the working tree.
    /// Destructive — callers confirm first.
    @discardableResult
    public func discardLines(_ selected: Set<DiffLineRef>, in diff: FileDiff, of change: FileChange) async -> Bool {
        guard change.area == .unstaged else { return false }
        return await applyLines(selected, in: diff, of: change, reverse: true, args: ["apply", "--reverse"])
    }

    private func applyLines(_ selected: Set<DiffLineRef>, in diff: FileDiff, of change: FileChange,
                            reverse: Bool, args: [String]) async -> Bool {
        guard let patch = PatchBuilder.patch(path: change.path, hunks: diff.hunks, selected: selected, reverse: reverse) else {
            lastError = GitError(args: args, exitCode: -1, stderr: "The selected lines don't change anything.")
            return false
        }
        return await perform(args + ["--whitespace=nowarn"], stdin: patch)
    }
}
