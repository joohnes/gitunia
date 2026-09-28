import XCTest
@testable import Gitunia

/// `PaletteRows.build` is the pure row model behind the ⌘K palette — a plain function of
/// plain values, no `WorkspaceStore`/SwiftUI, so the presence/order/filtering behaviour it decides
/// can be tested directly here instead of only observable by running the GUI.
final class PaletteRowsTests: XCTestCase {
    private func repo(_ name: String) -> PaletteRows.RepoEntry {
        PaletteRows.RepoEntry(id: name, name: name)
    }

    private let repos = ["zebra", "apple", "mango"].map { PaletteRows.RepoEntry(id: $0, name: $0) }

    // MARK: - Top level

    func testTopLevel_listsEveryActionWithNoPending() {
        let rows = PaletteRows.build(repositories: [], changeFilename: "", pending: nil, query: "")
        let actionIDs = Set(rows.compactMap { row -> String? in
            if case .action(let a) = row { return a.rawValue }
            return nil
        })
        XCTAssertEqual(actionIDs, [
            "fetchSelected", "pullSelected", "pushSelected", "forcePush", "undoLastCommit",
            "revertCommit", "cherryPick", "mergeBranch", "deleteBranch", "cleanUntracked", "removeFromGit", "compareWithMain", "goToCommit",
            "openInEditor", "refreshAll", "openWorkspace", "searchHistory", "fileHistory", "blame",
            "showReflog", "createBranchHere", "rebaseOnto", "stashWithMessage", "showStashes",
            "tags", "pushAllTags", "deleteMergedBranches", "createTag",
            "remotes", "fetchFromRemote", "setUpstream", "unsetUpstream", "gitConfig", "hooks", "sparseCheckout", "tidyCommits", "rewordHead",
            "cloneRepository", "newRepository", "worktrees",
            "newWindow", "saveWorkspaceAs", "addFolderToWorkspace", "addReposInFolder", "manageWorkspace",
            "nextChangedRepository", "previousChangedRepository", "markReviewed",
            "createPullRequest", "openPullRequest",
            "stashAll", "searchAllRepositories", "applyPatch", "copyDiffAsPatch",
            "startBisect", "bisectGood", "bisectBad", "bisectSkip", "bisectReset", "showActivity", "checkForUpdates",
        ], "submodule actions only appear when some repository has submodules")
    }

    func testWorkspaceActions_rankByTitle() {
        let manage = PaletteRows.build(repositories: repos, changeFilename: "", pending: nil, query: "manage")
        XCTAssertEqual(manage.first, .action(.manageWorkspace))
        XCTAssertEqual(PaletteRows.TopLevelAction.manageWorkspace.title(changeFilename: ""), "Manage Workspace…")
        let reposIn = PaletteRows.build(repositories: repos, changeFilename: "", pending: nil, query: "repos in")
        XCTAssertEqual(reposIn.first, .action(.addReposInFolder))
        XCTAssertEqual(PaletteRows.TopLevelAction.addReposInFolder.title(changeFilename: ""), "Add Repos in Folder…")
    }

    func testTopLevel_noAllRepositoriesRow() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: nil, query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    func testOpenInEditor_presentWithAndWithoutAnOpenDiff() {
        let withDiff = PaletteRows.build(repositories: [], changeFilename: "Foo.swift", pending: nil, query: "")
        let withoutDiff = PaletteRows.build(repositories: [], changeFilename: "", pending: nil, query: "")
        XCTAssertTrue(withDiff.contains(.action(.openInEditor)))
        XCTAssertTrue(withoutDiff.contains(.action(.openInEditor)))
    }

    // MARK: - Pending: All repositories row

    func testPendingFetch_allRepositoriesRowIsFirst() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .fetchSelected, query: "")
        XCTAssertEqual(rows.first, .allRepositories)
    }

    func testPendingPull_allRepositoriesRowIsFirst() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .pullSelected, query: "")
        XCTAssertEqual(rows.first, .allRepositories)
    }

    /// Push-all is a deliberate, confirmed write (see `CommandPalette`'s confirmation dialog), but
    /// it's still a bulk action reachable the same way fetch/pull are — so it gets the All row too.
    func testPendingPush_allRepositoriesRowIsFirst() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .pushSelected, query: "")
        XCTAssertEqual(rows.first, .allRepositories)
    }

    func testPendingUndo_noAllRepositoriesRow() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .undoLastCommit, query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    /// User decision: force push never offers "All" — it stays single-repository only, so bulk
    /// force-pushing is never one click away.
    func testPendingForcePush_noAllRepositoriesRow() {
        XCTAssertFalse(PaletteRows.TopLevelAction.forcePush.offersAll)
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .forcePush, query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    func testPendingFetch_onlyRepositoriesAfterAllRow() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .fetchSelected, query: "")
        XCTAssertEqual(rows.dropFirst().count, repos.count)
        for row in rows.dropFirst() {
            guard case .repository = row else { return XCTFail("expected only repository rows after All") }
        }
    }

    // MARK: - Filtering

    /// Deliberate ruling: the All row is a fixed, pinned convenience — it's exempt from the fuzzy
    /// filter, so a half-typed repo name never hides the "run everywhere" option.
    func testAllRow_isExemptFromFiltering() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .fetchSelected, query: "zzzznomatch")
        XCTAssertEqual(rows.first, .allRepositories)
    }

    func testTyping_filtersTheRepositoryList() {
        // .undoLastCommit, not .pushSelected — push now offers an All row (exempt from filtering, like fetch/pull),
        // which would otherwise be a second row in the expected result unrelated to what this test
        // is checking (repo-name filtering).
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .undoLastCommit, query: "man")
        XCTAssertEqual(rows, [.repository(repo("mango"))])
    }

    func testTyping_filtersDownToNothingLeavesOnlyAllRowWhenOffered() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .fetchSelected, query: "zzzznomatch")
        XCTAssertEqual(rows, [.allRepositories])
    }

    // MARK: - Ordering

    func testRepositories_orderedByNameRegardlessOfInputOrder() {
        // .undoLastCommit — no All row to strip out before checking repo order.
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .undoLastCommit, query: "")
        let names = rows.compactMap { row -> String? in
            if case .repository(let entry) = row { return entry.name }
            return nil
        }
        XCTAssertEqual(names, ["apple", "mango", "zebra"])
    }

    func testEmptyQuery_keepsNaturalOrder() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .undoLastCommit, query: "")
        XCTAssertEqual(rows, [repo("apple"), repo("mango"), repo("zebra")].map(PaletteRows.Row.repository))
    }

    // MARK: - T3: merge/delete branch top-level rows

    func testTopLevel_includesMergeAndDeleteBranchActions() {
        let rows = PaletteRows.build(repositories: [], changeFilename: "", pending: nil, query: "")
        XCTAssertTrue(rows.contains(.action(.mergeBranch)))
        XCTAssertTrue(rows.contains(.action(.deleteBranch)))
        // No `.renameBranch` case at all — rename needs a free-text step the palette doesn't have;
        // see the doc comment on `CommandPalette.pendingBranchStepRepo`.
    }

    func testMergeAndDeleteBranch_pickingARepoDoesNotOfferAllRow() {
        XCTAssertFalse(PaletteRows.TopLevelAction.mergeBranch.offersAll)
        XCTAssertFalse(PaletteRows.TopLevelAction.deleteBranch.offersAll)
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .mergeBranch, query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    func testMergeAndDeleteBranch_needBranchStep() {
        XCTAssertTrue(PaletteRows.TopLevelAction.mergeBranch.needsBranchStep)
        XCTAssertTrue(PaletteRows.TopLevelAction.deleteBranch.needsBranchStep)
        XCTAssertFalse(PaletteRows.TopLevelAction.undoLastCommit.needsBranchStep)
        XCTAssertFalse(PaletteRows.TopLevelAction.fetchSelected.needsBranchStep)
    }

    // MARK: - T4: delete untracked files top-level row

    func testTopLevel_includesCleanUntrackedAction() {
        let rows = PaletteRows.build(repositories: [], changeFilename: "", pending: nil, query: "")
        XCTAssertTrue(rows.contains(.action(.cleanUntracked)))
    }

    /// Single-repository only — deleting untracked files everywhere at once isn't a "run once"
    /// bulk action the way fetch/pull/push are, so there's no All row and no branch-style third
    /// step: picking a repository is the whole second step (`ContentView` opens the sheet from
    /// there, see `CommandPalette.onRequestCleanPreview`).
    func testCleanUntracked_pickingARepoDoesNotOfferAllRowOrBranchStep() {
        XCTAssertFalse(PaletteRows.TopLevelAction.cleanUntracked.offersAll)
        XCTAssertFalse(PaletteRows.TopLevelAction.cleanUntracked.needsBranchStep)
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .cleanUntracked, query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
        XCTAssertEqual(rows.count, repos.count)
    }

    // MARK: - T3: branch step (third level)

    private func branch(_ name: String, remote: Bool = false) -> PaletteRows.BranchEntry {
        PaletteRows.BranchEntry(id: remote ? "origin/\(name)" : name, name: remote ? "origin/\(name)" : name, isRemote: remote)
    }

    func testBranchStep_noAllRow() {
        let rows = PaletteRows.buildBranchStep(branches: [branch("main"), branch("feature")], query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    func testBranchStep_localBeforeRemoteThenAlphabetical() {
        let rows = PaletteRows.buildBranchStep(
            branches: [branch("zebra"), branch("main", remote: true), branch("apple")],
            query: ""
        )
        let names = rows.compactMap { row -> String? in
            if case .branch(let b) = row { return b.name }
            return nil
        }
        XCTAssertEqual(names, ["apple", "zebra", "origin/main"])
    }

    func testBranchStep_filtersByQuery() {
        let rows = PaletteRows.buildBranchStep(branches: [branch("main"), branch("feature/login")], query: "login")
        XCTAssertEqual(rows, [.branch(branch("feature/login"))])
    }

    // MARK: - Integration round: recovery / rebase-stash / tags / remotes / repos actions

    private let repoOnlyActions: [PaletteRows.TopLevelAction] = [
        .showReflog, .createBranchHere, .stashWithMessage, .showStashes, .tags, .pushAllTags,
        .deleteMergedBranches, .createTag, .remotes, .unsetUpstream, .worktrees, .submodules, .updateSubmodules, .markReviewed,
        .createPullRequest, .openPullRequest,
        .gitConfig, .hooks, .sparseCheckout, .tidyCommits, .rewordHead, .applyPatch, .copyDiffAsPatch,
        .startBisect, .bisectGood, .bisectBad, .bisectSkip, .bisectReset,
    ]
    private let branchStepActions: [PaletteRows.TopLevelAction] = [.rebaseOnto, .fetchFromRemote, .setUpstream]

    /// Each goes to a repository step with no All row; only rebase / fetch-from / set-upstream
    /// continue to a third step.
    func testNewActions_repositoryStepNoAllRow() {
        for action in repoOnlyActions + branchStepActions {
            XCTAssertTrue(action.needsRepository, "\(action) should need a repository")
            XCTAssertFalse(action.offersAll, "\(action)")
            XCTAssertEqual(action.needsBranchStep, branchStepActions.contains(action), "\(action)")
        }
    }

    func testCloneAndNewRepository_runImmediately() {
        XCTAssertFalse(PaletteRows.TopLevelAction.cloneRepository.needsRepository)
        XCTAssertFalse(PaletteRows.TopLevelAction.newRepository.needsRepository)
    }

    func testRepositoryStep_listsEveryRepository() {
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .showReflog, query: "")
        XCTAssertEqual(rows.count, repos.count)
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    // Submodules: offered only when a repository has them, and only those are listed.

    private let withSubmodules = [
        PaletteRows.RepoEntry(id: "app", name: "app", hasSubmodules: true),
        PaletteRows.RepoEntry(id: "lib", name: "lib"),
    ]

    func testSubmoduleActions_offeredOnlyWhenSomeRepoHasSubmodules() {
        let without = PaletteRows.build(repositories: repos, changeFilename: "", pending: nil, query: "")
        XCTAssertFalse(without.contains(.action(.submodules)))
        XCTAssertFalse(without.contains(.action(.updateSubmodules)))
        let with = PaletteRows.build(repositories: withSubmodules, changeFilename: "", pending: nil, query: "")
        XCTAssertTrue(with.contains(.action(.submodules)))
        XCTAssertTrue(with.contains(.action(.updateSubmodules)))
    }

    func testSubmoduleActions_repositoryStepListsOnlyReposWithSubmodules() {
        for pending in [PaletteRows.TopLevelAction.submodules, .updateSubmodules] {
            let rows = PaletteRows.build(repositories: withSubmodules, changeFilename: "", pending: pending, query: "")
            XCTAssertEqual(rows, [.repository(withSubmodules[0])])
        }
        // Everything else still lists every repository.
        let rows = PaletteRows.build(repositories: withSubmodules, changeFilename: "", pending: .worktrees, query: "")
        XCTAssertEqual(rows.count, 2)
    }

    func testNewActions_findableByName() {
        let rows = PaletteRows.build(repositories: [], changeFilename: "", pending: nil, query: "rebase onto")
        XCTAssertEqual(rows.first, .action(.rebaseOnto))
        let reflog = PaletteRows.build(repositories: [], changeFilename: "", pending: nil, query: "reflog")
        XCTAssertEqual(reflog.first, .action(.showReflog))
    }

    // Third step contents per action (`branchStepEntries`).

    private var stepBranches: [PaletteRows.BranchEntry] {
        [
            PaletteRows.BranchEntry(id: "main", name: "main", isRemote: false, isCurrent: true),
            PaletteRows.BranchEntry(id: "feature", name: "feature", isRemote: false),
            PaletteRows.BranchEntry(id: "origin/main", name: "origin/main", isRemote: true),
        ]
    }

    private func names(_ entries: [PaletteRows.BranchEntry]) -> [String] { entries.map(\.name) }

    func testBranchStepEntries_mergeAndRebaseExcludeCurrentOnly() {
        for pending in [PaletteRows.TopLevelAction.mergeBranch, .rebaseOnto] {
            XCTAssertEqual(names(PaletteRows.branchStepEntries(for: pending, branches: stepBranches, remotes: [])), ["feature", "origin/main"], "\(pending)")
        }
    }

    func testBranchStepEntries_deleteIsLocalNonCurrent() {
        XCTAssertEqual(names(PaletteRows.branchStepEntries(for: .deleteBranch, branches: stepBranches, remotes: [])), ["feature"])
    }

    func testBranchStepEntries_setUpstreamIsRemoteBranchesOnly() {
        XCTAssertEqual(names(PaletteRows.branchStepEntries(for: .setUpstream, branches: stepBranches, remotes: ["origin"])), ["origin/main"])
    }

    func testBranchStepEntries_fetchFromRemoteListsRemotes() {
        XCTAssertTrue(PaletteRows.TopLevelAction.fetchFromRemote.picksRemote)
        let entries = PaletteRows.branchStepEntries(for: .fetchFromRemote, branches: stepBranches, remotes: ["origin", "upstream"])
        XCTAssertEqual(names(entries), ["origin", "upstream"])
        let rows = PaletteRows.buildBranchStep(branches: entries, query: "up")
        XCTAssertEqual(rows.map(\.id), ["branch:remote:upstream"])
    }
}
