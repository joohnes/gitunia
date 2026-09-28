import SwiftUI
import GituniaCore

/// Which per-repository sheet is up. One per window, owned by `WindowContent` and published
/// as a focused value (so File-menu commands can set it) and through the environment (sidebar,
/// toolbar, History, ⌘K) — read optionally, so views rendered without it (render tests) keep working.
/// Each case carries its repository: ⌘K can target any repository, not just the selected one.
@MainActor
@Observable
final class RepoSheets {
    enum Sheet: Identifiable {
        case clone, newRepository, manageWorkspace
        case submodules(RepositoryStore)
        case worktrees(RepositoryStore)
        case applyPatch(RepositoryStore, String) // initial patch text ("" from the palette)
        case rewordHead(RepositoryStore)
        case remotes(RepositoryStore)
        case tags(RepositoryStore)
        case createTag(RepositoryStore, CommitInfo)
        case mergedCleanup(RepositoryStore)
        case stashes(RepositoryStore)
        case config(RepositoryStore)
        case hooks(RepositoryStore)
        case sparseCheckout(RepositoryStore)
        /// Tidy Commits; `since` limits it to that commit and newer (History's "Tidy commits from here…").
        case interactiveRebase(RepositoryStore, since: String? = nil)
        /// `good` pre-fills the good commit (History's "Bisect: Mark as Good…").
        case startBisect(RepositoryStore, good: String = "")
        case removeFromGit(RepositoryStore, [String])
        var id: String {
            switch self {
            case .clone: "clone"
            case .newRepository: "new"
            case .manageWorkspace: "manage"
            case .submodules(let s): "submodules:\(s.id.path)"
            case .worktrees(let s): "worktrees:\(s.id.path)"
            case .applyPatch(let s, _): "patch:\(s.id.path)"
            case .rewordHead(let s): "reword:\(s.id.path)"
            case .remotes(let s): "remotes:\(s.id.path)"
            case .tags(let s): "tags:\(s.id.path)"
            case .createTag(let s, let c): "tag-\(c.hash):\(s.id.path)"
            case .mergedCleanup(let s): "merged:\(s.id.path)"
            case .stashes(let s): "stashes:\(s.id.path)"
            case .config(let s): "config:\(s.id.path)"
            case .hooks(let s): "hooks:\(s.id.path)"
            case .sparseCheckout(let s): "sparse:\(s.id.path)"
            case .interactiveRebase(let s, let since): "tidy-\(since ?? ""):\(s.id.path)"
            case .startBisect(let s, let good): "bisect-\(good):\(s.id.path)"
            case .removeFromGit(let s, let paths): "rm-\(paths.joined(separator: "|")):\(s.id.path)"
            }
        }
    }
    var active: Sheet?
}

struct RepoSheetsPresenter: ViewModifier {
    @Bindable var sheets: RepoSheets
    var workspace: WorkspaceStore
    @Environment(ToastCenter.self) private var toasts
    @State private var stashSelection: StashItem.ID?

    func body(content: Content) -> some View {
        content.sheet(item: $sheets.active, onDismiss: { stashSelection = nil }) { sheet in
            switch sheet {
            case .clone: CloneRepositorySheet(workspace: workspace)
            case .newRepository: NewRepositorySheet(workspace: workspace)
            case .manageWorkspace: ManageWorkspaceSheet(workspace: workspace)
            case .submodules(let store): SubmodulesSheet(store: store, workspace: workspace)
            case .worktrees(let store): WorktreesSheet(store: store, workspace: workspace)
            case .applyPatch(let store, let text): ApplyPatchSheet(repo: store, initialText: text)
            case .rewordHead(let store): RewordCommitSheet(repo: store, stripTrailers: workspace.config.settings.stripAgentTrailers)
            case .remotes(let store): RemotesSheet(store: store, workspace: workspace, toasts: toasts)
            case .tags(let store): TagsSheet(repo: store)
            case .createTag(let store, let commit): CreateTagSheet(repo: store, commit: commit)
            case .mergedCleanup(let store): MergedBranchesSheet(repo: store)
            case .stashes(let store): StashesSheet(repo: store, selection: $stashSelection)
            case .config(let store): GitConfigSheet(repo: store, editorBundleID: workspace.config.settings.editorBundleID)
            case .hooks(let store): HooksSheet(repo: store)
            case .sparseCheckout(let store): SparseCheckoutSheet(repo: store)
            case .interactiveRebase(let store, let since): InteractiveRebaseSheet(repo: store, since: since)
            case .startBisect(let store, let good): BisectStartSheet(repo: store, good: good)
            case .removeFromGit(let store, let paths): RemoveFromGitSheet(repo: store, paths: paths)
            }
        }
    }
}

// MARK: - Shared by the repository sheets

/// "~/Desktop/monozu/x" instead of the full home path — shorter and never leaks anything new.
func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

struct SheetError: View {
    let message: String
    var body: some View {
        ScrollView {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 90)
    }
}

/// A sheet's git operation: holds `busy`, clears `error`, and on failure shows git's stderr
/// trimmed with credentials redacted. `then` runs after either outcome, before `busy` drops.
@MainActor
enum SheetActionRunner {
    static func run(busy: Binding<Bool>, error: Binding<String?>, _ op: @escaping () async -> GitError?,
                    onSuccess: @escaping () async -> Void, then: @escaping () async -> Void = {}) {
        busy.wrappedValue = true
        error.wrappedValue = nil
        Task {
            if let e = await op() {
                error.wrappedValue = RepoURL.redactingCredentials(e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                await onSuccess()
            }
            await then()
            busy.wrappedValue = false
        }
    }
}
