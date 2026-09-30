import GituniaCore

/// The palette's row list as a pure function of plain values — no `WorkspaceStore`, no SwiftUI,
/// so it's testable without a GUI harness (see Tests/GituniaTests/PaletteRowsTests). Running an
/// action has side effects, so that stays in the view (`CommandPalette+Actions.swift`).
enum PaletteRows {
    /// Plain stand-in for a `RepositoryStore` — just enough to render and filter a row.
    struct RepoEntry: Identifiable, Equatable {
        let id: String
        let name: String
        /// Gates the submodule actions (only offered when some repository has submodules, and
        /// their repository step lists only those).
        var hasSubmodules = false
    }

    /// Everything the palette shows for one action. `chip` is set only for actions that need a
    /// repository picked first — it labels the search field while that pick is pending.
    struct Spec {
        let title: String
        let icon: String
        var chip: String? = nil
    }

    /// Raw values are row ids (`Row.id`) — keep them stable. Declaration order is row order.
    enum TopLevelAction: String, Equatable, CaseIterable {
        case fetchSelected, pullSelected, pushSelected, forcePush, undoLastCommit, revertCommit, cherryPick
        case mergeBranch, deleteBranch, cleanUntracked, removeFromGit, compareWithMain, goToCommit
        case openInEditor, fileHistory, blame, refreshAll, openWorkspace, searchHistory
        case newWindow, saveWorkspaceAs, addFolderToWorkspace, addReposInFolder, manageWorkspace
        case nextChangedRepository, previousChangedRepository
        case showReflog, createBranchHere, rebaseOnto, stashWithMessage, showStashes
        case tags, pushAllTags, deleteMergedBranches, createTag
        case remotes, fetchFromRemote, setUpstream, unsetUpstream
        case cloneRepository, newRepository, worktrees, submodules, updateSubmodules
        case markReviewed
        case gitConfig
        case hooks
        case sparseCheckout
        case tidyCommits, rewordHead
        case createPullRequest, openPullRequest
        case applyPatch, copyDiffAsPatch
        case startBisect, bisectGood, bisectBad, bisectSkip, bisectReset
        case stashAll, searchAllRepositories
        case showActivity, checkForUpdates

        var spec: Spec {
            switch self {
            case .fetchSelected: Spec(title: "Fetch", icon: "arrow.triangle.2.circlepath", chip: "Fetch")
            case .pullSelected: Spec(title: "Pull", icon: "arrow.down.circle", chip: "Pull")
            case .pushSelected: Spec(title: "Push", icon: "arrow.up.circle", chip: "Push")
            case .forcePush: Spec(title: "Force push", icon: "exclamationmark.triangle", chip: "Force push")
            case .undoLastCommit: Spec(title: "Undo last commit", icon: "arrow.uturn.backward.circle", chip: "Undo last commit")
            case .revertCommit: Spec(title: "Revert commit", icon: "arrow.uturn.left.circle")
            case .cherryPick: Spec(title: "Cherry-pick", icon: "arrow.triangle.branch")
            case .mergeBranch: Spec(title: "Merge branch", icon: "arrow.triangle.merge", chip: "Merge branch")
            case .deleteBranch: Spec(title: "Delete branch", icon: "trash", chip: "Delete branch")
            case .cleanUntracked: Spec(title: "Delete Untracked Files…", icon: "trash", chip: "Delete untracked files")
            case .removeFromGit: Spec(title: "Remove from Git…", icon: "minus.circle", chip: "Remove from Git")
            case .compareWithMain: Spec(title: "Compare with master", icon: "arrow.left.arrow.right", chip: "Compare with master")
            case .goToCommit: Spec(title: "Go to Commit…", icon: "number", chip: "Go to commit")
            case .openInEditor: Spec(title: "Open in editor", icon: "square.and.pencil")
            case .fileHistory: Spec(title: "File history", icon: "clock")
            case .blame: Spec(title: "Blame", icon: "person.text.rectangle")
            case .refreshAll: Spec(title: "Refresh All", icon: "arrow.clockwise")
            case .openWorkspace: Spec(title: "Open Workspace…", icon: "folder")
            case .searchHistory: Spec(title: "Search History…", icon: "magnifyingglass")
            case .newWindow: Spec(title: "New Window", icon: "macwindow.badge.plus")
            case .saveWorkspaceAs: Spec(title: "Save Workspace As…", icon: "square.and.arrow.down")
            case .addFolderToWorkspace: Spec(title: "Add Folder to Workspace…", icon: "plus.rectangle.on.folder")
            case .addReposInFolder: Spec(title: "Add Repos in Folder…", icon: "folder.badge.plus")
            case .manageWorkspace: Spec(title: "Manage Workspace…", icon: "list.bullet.rectangle")
            case .nextChangedRepository: Spec(title: "Next changed repository", icon: "arrow.down.circle.dotted")
            case .previousChangedRepository: Spec(title: "Previous changed repository", icon: "arrow.up.circle.dotted")
            case .showReflog: Spec(title: "Show Reflog…", icon: "clock.arrow.circlepath", chip: "Reflog")
            case .createBranchHere: Spec(title: "Create Branch Here…", icon: "arrow.triangle.branch", chip: "Create branch here")
            case .rebaseOnto: Spec(title: "Rebase current branch onto…", icon: "arrow.triangle.pull", chip: "Rebase onto")
            case .stashWithMessage: Spec(title: "Stash with Message…", icon: "tray.and.arrow.down", chip: "Stash with message")
            case .showStashes: Spec(title: "Show Stashes…", icon: "tray.full", chip: "Stashes")
            case .tags: Spec(title: "Tags…", icon: "tag", chip: "Tags")
            case .pushAllTags: Spec(title: "Push All Tags…", icon: "tag.circle", chip: "Push all tags")
            case .deleteMergedBranches: Spec(title: "Delete Merged Branches…", icon: "arrow.triangle.merge", chip: "Delete merged branches")
            case .createTag: Spec(title: "Create Tag at HEAD…", icon: "tag", chip: "Tag HEAD")
            case .remotes: Spec(title: "Remotes…", icon: "network", chip: "Remotes")
            case .fetchFromRemote: Spec(title: "Fetch from Remote…", icon: "arrow.triangle.2.circlepath", chip: "Fetch from")
            case .setUpstream: Spec(title: "Set Upstream…", icon: "arrow.up.arrow.down", chip: "Set upstream")
            case .unsetUpstream: Spec(title: "Unset Upstream", icon: "arrow.up.arrow.down", chip: "Unset upstream")
            case .cloneRepository: Spec(title: "Clone Repository…", icon: "square.and.arrow.down")
            case .newRepository: Spec(title: "New Repository…", icon: "plus.rectangle.on.folder")
            case .worktrees: Spec(title: "Worktrees…", icon: "rectangle.split.3x1", chip: "Worktrees")
            case .submodules: Spec(title: "Submodules…", icon: "shippingbox", chip: "Submodules")
            case .updateSubmodules: Spec(title: "Update Submodules…", icon: "shippingbox.and.arrow.backward", chip: "Update submodules")
            case .markReviewed: Spec(title: "Mark reviewed", icon: "checkmark.circle", chip: "Mark reviewed")
            case .gitConfig: Spec(title: "Git Config…", icon: "gearshape.2", chip: "Git config")
            case .hooks: Spec(title: "Hooks…", icon: "bolt", chip: "Hooks")
            case .sparseCheckout: Spec(title: "Sparse Checkout…", icon: "square.dashed.inset.filled", chip: "Sparse checkout")
            case .tidyCommits: Spec(title: "Tidy Commits…", icon: "wand.and.stars", chip: "Tidy commits")
            case .rewordHead: Spec(title: "Reword Last Commit…", icon: "pencil", chip: "Reword last commit")
            case .createPullRequest: Spec(title: "Create Pull Request…", icon: "arrow.triangle.pull", chip: "Create pull request")
            case .openPullRequest: Spec(title: "Open Pull Request in Browser", icon: "arrow.triangle.pull", chip: "Open pull request")
            case .applyPatch: Spec(title: "Apply Patch…", icon: "doc.badge.plus", chip: "Apply patch")
            case .copyDiffAsPatch: Spec(title: "Copy Diff as Patch", icon: "doc.on.clipboard", chip: "Copy diff as patch")
            case .startBisect: Spec(title: "Start Bisect…", icon: "scope", chip: "Start bisect")
            case .bisectGood: Spec(title: "Bisect: Good", icon: "checkmark.circle", chip: "Bisect: good")
            case .bisectBad: Spec(title: "Bisect: Bad", icon: "xmark.circle", chip: "Bisect: bad")
            case .bisectSkip: Spec(title: "Bisect: Skip", icon: "forward.circle", chip: "Bisect: skip")
            case .bisectReset: Spec(title: "Bisect: Reset", icon: "arrow.uturn.backward.circle", chip: "Bisect: reset")
            case .stashAll: Spec(title: "Stash all changed repositories…", icon: "tray.2")
            case .searchAllRepositories: Spec(title: "Search in all repositories…", icon: "text.magnifyingglass")
            case .showActivity: Spec(title: "Show Activity", icon: "bell.badge")
            case .checkForUpdates: Spec(title: "Check for Updates…", icon: "arrow.down.app")
            }
        }

        func title(changeFilename: String) -> String {
            self == .openInEditor && !changeFilename.isEmpty ? "Open \(changeFilename) in editor" : spec.title
        }

        /// Picking this action moves to a repository step instead of running it.
        var needsRepository: Bool { spec.chip != nil }
        var chipLabel: String { spec.chip ?? spec.title }

        /// Only fetch/pull/push make sense across every repository at once. Force push stays
        /// single-repository by user decision; branch-picking actions have no cross-repo meaning.
        var offersAll: Bool { self == .fetchSelected || self == .pullSelected || self == .pushSelected }

        /// Picking a repository moves to a third step (a branch, or a remote for Fetch from).
        var needsBranchStep: Bool {
            [.mergeBranch, .deleteBranch, .rebaseOnto, .fetchFromRemote, .setUpstream, .removeFromGit].contains(self)
        }

        /// The third step lists remotes rather than branches.
        var picksRemote: Bool { self == .fetchFromRemote }

        /// The third step lists tracked files and folders rather than branches.
        var picksPath: Bool { self == .removeFromGit }

        /// The repository step lists only repositories with submodules.
        var needsSubmodules: Bool { self == .submodules || self == .updateSubmodules }
    }

    /// A row in the third step — plain stand-in for a `BranchInfo` (or a remote name).
    struct BranchEntry: Identifiable, Equatable {
        let id: String
        let name: String
        let isRemote: Bool
        var isCurrent = false
    }

    enum Row: Identifiable, Equatable {
        case action(TopLevelAction)
        case allRepositories
        case repository(RepoEntry)
        case branch(BranchEntry)

        var id: String {
            switch self {
            case .action(let action): return "action:\(action.rawValue)"
            case .allRepositories: return "all-repositories"
            case .repository(let entry): return "repo:\(entry.id)"
            case .branch(let entry): return "branch:\(entry.id)"
            }
        }
    }

    /// Top level: every action plus every repository, fuzzy-ranked together by `query`. With
    /// `pending` set: the repository picker — "All repositories" pinned first when offered (exempt
    /// from filtering, so a half-typed name never hides it), then repositories filtered by `query`.
    ///
    /// Repositories are sorted by name, never by change state, and all of them are searched (not
    /// `visibleRepositories`) — so filtered-out repos stay reachable and rows don't reorder under
    /// the highlight while agents write to repos mid-keystroke.
    static func build(
        repositories: [RepoEntry],
        changeFilename: String,
        pending: TopLevelAction?,
        query: String
    ) -> [Row] {
        let sortedRepos = repositories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let pending {
            let candidates = pending.needsSubmodules ? sortedRepos.filter(\.hasSubmodules) : sortedRepos
            let filtered = FuzzyMatch.rank(candidates.map(Row.repository), query: query) { row in
                if case .repository(let entry) = row { return entry.name }
                return ""
            }
            return pending.offersAll ? [.allRepositories] + filtered : filtered
        }

        // Every action, always — one that can't run says why in a toast. The exception is the
        // submodule pair, which only means something when some repository has submodules.
        let anySubmodules = repositories.contains(where: \.hasSubmodules)
        let actionRows: [Row] = TopLevelAction.allCases
            .filter { anySubmodules || !$0.needsSubmodules }
            .map(Row.action)
        let repoRows = sortedRepos.map(Row.repository)
        return FuzzyMatch.rank(repoRows + actionRows, query: query) { row in
            switch row {
            case .repository(let entry): return entry.name
            case .action(let action): return action.title(changeFilename: changeFilename)
            case .allRepositories, .branch: return ""
            }
        }
    }

    /// What the third step offers for `pending`, before filtering by the query:
    /// - merge, rebase onto: every branch but the checked-out one;
    /// - delete: local branches but the checked-out one (`git branch -d` can't delete remote names);
    /// - set upstream: remote-tracking branches only;
    /// - fetch from remote: the repository's remotes;
    /// - remove from Git: tracked files and folders (`RepositoryStore.trackedPaths`).
    static func branchStepEntries(for pending: TopLevelAction, branches: [BranchEntry], remotes: [String], paths: [String] = []) -> [BranchEntry] {
        switch pending {
        case .removeFromGit:
            return paths.map { BranchEntry(id: "path:\($0)", name: $0, isRemote: false) }
        case .fetchFromRemote:
            return remotes.map { BranchEntry(id: "remote:\($0)", name: $0, isRemote: true) }
        case .setUpstream:
            return branches.filter(\.isRemote)
        case .deleteBranch:
            return branches.filter { !$0.isCurrent && !$0.isRemote }
        default:
            return branches.filter { !$0.isCurrent }
        }
    }

    /// The third step renders its rows in a plain `VStack` (see `CommandPalette.body`), so with
    /// thousands of branches only this many are built; the rest wait for a narrower query.
    static let branchStepLimit = 100

    /// Third step: fuzzy-filtered entries, no "All" row, capped at `branchStepLimit` — `hidden` is
    /// how many matches were cut. Local branches sort before remote ones so `main` outranks
    /// `origin/main`, then alphabetically (by a lowercased key computed once, not a localized
    /// compare per comparison) within each group.
    static func buildBranchStep(branches: [BranchEntry], query: String) -> (rows: [Row], hidden: Int) {
        let sorted = branches.map { (key: $0.name.lowercased(), entry: $0) }
            .sorted {
                if $0.entry.isRemote != $1.entry.isRemote { return !$0.entry.isRemote }
                return $0.key < $1.key
            }
            .map(\.entry)
        let ranked = FuzzyMatch.rank(sorted, query: query, key: \.name)
        return (ranked.prefix(branchStepLimit).map(Row.branch), max(ranked.count - branchStepLimit, 0))
    }
}
