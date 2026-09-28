import SwiftUI
import GituniaCore

/// The content column's top row: the Changes/History/Compare switch plus icon buttons for the
/// current mode's working-tree actions. Icon-only so the row fits the column's 280pt minimum;
/// `.help` tooltips carry the words. Internal (not private) so `ActionRowRenderTests` can render it.
struct ContentActionRow: View {
    var repo: RepositoryStore
    @Binding var contentMode: ContentMode
    var onDiscardAllRequested: () -> Void
    var onUndoRequested: () -> Void
    var onCleanUntrackedRequested: () -> Void

    var body: some View {
        // Spacing/padding sized so the five Changes-mode icons plus stash fit at the column's 280pt
        // minimum (ActionRowRenderTests.testRender_actionRowWithClean renders exactly 280).
        HStack(spacing: 3) {
            Picker("Mode", selection: $contentMode) {
                ForEach(ContentMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 0)

            switch contentMode {
            case .changes: changesActions
            case .history: historyActions
            // Compare's controls all live in `CompareView`'s own header.
            case .compare: EmptyView()
            }
        }
        // `.small` shrinks the picker and the icon buttons together — needed to fit the 280pt
        // minimum (see ActionRowRenderTests.testRender_changesActionRow300).
        .controlSize(.small)
        // One look for every control in the row: `Menu` otherwise picks its own (tinted) style
        // in an active window, which made the stash menu stand out orange from its siblings.
        .buttonStyle(.bordered)
        .menuStyle(.button)
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(.bar)
    }

    private struct RowAction {
        let title: String
        let icon: String
        let help: String
        let disabled: Bool
        let action: () -> Void
    }

    private var changesRowActions: [RowAction] {
        [
            RowAction(title: "Stage All", icon: "plus.square.on.square", help: "Stage all changes",
                      disabled: repo.isBusy || (repo.unstagedChanges.isEmpty && repo.untrackedChanges.isEmpty),
                      action: { Task { await stageAll() } }),
            // Not "minus.square.on.square" — that isn't a real SF Symbol and renders blank.
            RowAction(title: "Unstage All", icon: "minus.square", help: "Unstage all staged changes",
                      disabled: repo.isBusy || repo.stagedChanges.isEmpty,
                      action: { Task { await unstageAll() } }),
            RowAction(title: "Discard Tracked Changes…", icon: "arrow.uturn.backward",
                      help: "Discard tracked, unstaged changes — untracked files are left alone",
                      disabled: repo.isBusy || repo.unstagedChanges.isEmpty, action: onDiscardAllRequested),
            RowAction(title: "Delete Untracked Files…", icon: "trash",
                      help: "Delete untracked files… — not in git, can't be undone by git",
                      disabled: repo.isBusy || repo.untrackedChanges.isEmpty, action: onCleanUntrackedRequested),
        ]
    }

    /// Full icon row when it fits, otherwise the working-tree actions fold into one overflow menu
    /// (the segmented picker can't shrink). Stash stays outside either way: it's a menu already.
    @ViewBuilder
    private var changesActions: some View {
        let actions = changesRowActions
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                ForEach(actions, id: \.icon) { item in
                    Button(action: item.action) { Image(systemName: item.icon) }
                        .help(item.help)
                        .disabled(item.disabled)
                }
            }
            Menu {
                ForEach(actions, id: \.icon) { item in
                    Button(item.title, systemImage: item.icon, action: item.action)
                        .disabled(item.disabled)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("Working tree actions")
        }
        StashMenu(repo: repo)
    }

    @ViewBuilder
    private var historyActions: some View {
        Button(action: onUndoRequested) {
            Image(systemName: "arrow.uturn.backward.circle")
        }
        // Says *why* when disabled.
        .help(repo.isBusy ? "Busy — try again in a moment"
              : !repo.hasParentCommit ? "This is the first commit — nothing to undo to"
              : "Undo the last commit — soft reset, nothing is lost")
        .disabled(repo.isBusy || !repo.hasParentCommit)
    }

    /// Plain `git add -A` normally, but a per-file loop whenever a conflict is present —
    /// `git add -A` would silently mark a conflicted path resolved.
    private func stageAll() async {
        if repo.conflictedChanges.isEmpty {
            await repo.stageAll()
        } else {
            for change in repo.unstagedChanges + repo.untrackedChanges { await repo.stage(change) }
        }
    }

    /// Same trade in the other direction: a bare `git reset -q` touches the whole index, so any
    /// conflict means a per-file loop rather than risk disturbing its unmerged entries.
    private func unstageAll() async {
        if repo.conflictedChanges.isEmpty {
            await repo.unstageAll()
        } else {
            for change in repo.stagedChanges { await repo.unstage(change) }
        }
    }
}
