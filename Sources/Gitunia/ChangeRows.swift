import SwiftUI
import GituniaCore

/// A conflicted file's row: same look as `ChangeRow` plus inline resolution buttons. Kept
/// separate from `ChangeRow` rather than adding an `isConflicted` branch there, since it carries
/// actions (and their enablement) `ChangeRow` has no reason to know about.
struct ConflictRow: View {
    let change: FileChange
    /// Whether to show the resolution buttons (their labels flip during a rebase — see
    /// `ChangesView.mineLabel`).
    let offerResolution: Bool
    /// "Use Mine" during a merge, "Keep Upstream" during a rebase — see `RepositoryStore.useOurs`.
    var mineLabel: String = "Use Mine"
    /// "Use Theirs" during a merge, "Keep My Commit" during a rebase — see `RepositoryStore.useTheirs`.
    var theirsLabel: String = "Use Theirs"
    let useMine: () -> Void
    let useTheirs: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("!")
                .font(.caption.monospaced().bold())
                .frame(width: 16)
                .foregroundStyle(Theme.status(.conflicted))
            VStack(alignment: .leading, spacing: 1) {
                Text((change.path as NSString).lastPathComponent)
                Text((change.path as NSString).deletingLastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            if offerResolution {
                Spacer()
                Button(mineLabel, action: useMine)
                    .buttonStyle(.bordered).controlSize(.small)
                Button(theirsLabel, action: useTheirs)
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

/// Pinned above the file lists while a merge/rebase/cherry-pick/revert (or bisect) is in progress.
/// `Continue`/`Skip` run immediately — both are easy to recover from — while `Abort` confirms
/// first, since it throws away any conflict resolution done so far. Skip only exists for
/// rebase/cherry-pick (see `RepositoryStore.skipOperation`).
struct OperationBanner: View {
    let operation: GitOperation
    /// Disabled while conflicts remain — continuing (which commits, for a merge) on top of
    /// unresolved conflicts either fails outright or commits half-resolved content.
    let continueDisabled: Bool
    var onContinue: () -> Void
    var onSkip: () -> Void
    var onAbort: () -> Void

    private var title: String {
        switch operation {
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase in progress"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        case .bisect: return "Bisect in progress — use the History bar"
        }
    }

    private var continueHelp: String {
        switch operation {
        case .merge: return "git -c core.editor=true merge --continue"
        case .rebase: return "git -c core.editor=true rebase --continue"
        case .cherryPick: return "git -c core.editor=true cherry-pick --continue"
        case .revert: return "git -c core.editor=true revert --continue"
        case .bisect: return ""
        }
    }

    private var abortHelp: String {
        switch operation {
        case .merge: return "git merge --abort"
        case .rebase: return "git rebase --abort"
        case .cherryPick: return "git cherry-pick --abort"
        case .revert: return "git revert --abort"
        case .bisect: return "git bisect reset"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.brand)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if operation != .bisect {
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(continueDisabled)
                    .help(continueDisabled ? "Resolve the remaining conflicts before continuing" : continueHelp)
            }
            if operation == .rebase || operation == .cherryPick {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered).controlSize(.small)
                    .help(operation == .rebase ? "git rebase --skip" : "git cherry-pick --skip")
            }
            Button(operation == .bisect ? "Reset" : "Abort", role: .destructive, action: onAbort)
                .buttonStyle(.bordered).controlSize(.small)
                .help(abortHelp)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.brand.opacity(0.12))
    }
}

struct ChangeRow: View {
    let change: FileChange
    /// False in tree mode: the directory row above already says where the file lives.
    var showsPath: Bool = true
    /// Matches a `filter=lfs` rule in `.gitattributes` — git stores a pointer, not the bytes.
    var isLFS: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(letter)
                .font(.caption.monospaced().bold())
                .frame(width: 16)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text((change.path as NSString).lastPathComponent)
                if showsPath {
                    Text((change.path as NSString).deletingLastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            if isLFS {
                Text("LFS")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .fixedSize()
                    .help("Tracked by Git LFS")
            }
            if let size = change.size, size > 1_000_000 {
                Spacer(minLength: 4)
                Text(Int64(size).formatted(.byteCount(style: .file)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var letter: String {
        switch change.status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    private var color: Color {
        Theme.status(change.status)
    }
}
