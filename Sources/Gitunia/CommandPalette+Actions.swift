import SwiftUI
import GituniaCore

/// Bulk-op summary toast shared by the menu bar's Fetch/Pull all, ⌘⇧F/L/P and the palette's
/// "All repositories" row, so they all say the same thing.
enum RemoteActionRunner {
    @MainActor
    static func postBulkResult(_ op: BulkOperation, kind: String, toasts: ToastCenter) {
        if op.failures.isEmpty {
            toasts.post(.success("\(kind) \(op.completed) of \(op.total)"))
        } else {
            let detail = op.failures.map { "\($0.repo): \($0.message)" }.joined(separator: "\n")
            toasts.post(.error("\(kind) \(op.completed) of \(op.total)", detail: detail, stderr: detail))
        }
    }
}

extension CommandPalette {
    func run(_ row: PaletteRows.Row) {
        switch row {
        case .action(let action) where action.needsRepository:
            // Nothing runs yet — the action becomes the chip and the repository picker opens.
            pendingAction = action
            query = ""
        case .action(.openInEditor):
            isPresented = false
            openInEditor()
        case .action(.revertCommit):
            requestRevert()
        case .action(.cherryPick):
            requestCherryPick()
        case .action(.refreshAll):
            isPresented = false
            Task { await workspace.refreshAll() }
        case .action(.openWorkspace):
            isPresented = false
            openWorkspace()
        case .action(.newWindow):
            isPresented = false
            newWindow()
        case .action(.checkForUpdates):
            isPresented = false
            updates?.checkIfDue(force: true)
        case .action(.showActivity):
            isPresented = false
            openWindow(id: "activity")
        case .action(.saveWorkspaceAs):
            isPresented = false
            WorkspaceActions.saveAs(workspace, toasts: toasts)
        case .action(.addFolderToWorkspace):
            isPresented = false
            WorkspaceActions.addFolder(to: workspace, toasts: toasts)
        case .action(.addReposInFolder):
            isPresented = false
            WorkspaceActions.addReposInFolder(to: workspace, toasts: toasts)
        case .action(.manageWorkspace):
            isPresented = false
            repoSheets?.active = .manageWorkspace
        case .action(.nextChangedRepository):
            isPresented = false
            workspace.selectAdjacentChanged(forward: true)
        case .action(.previousChangedRepository):
            isPresented = false
            workspace.selectAdjacentChanged(forward: false)
        case .action(.searchHistory):
            isPresented = false
            onRequestSearchHistory()
        case .action(.fileHistory):
            requestFileHistoryFromPalette()
        case .action(.blame):
            isPresented = false
            onRequestBlame()
        case .action(.cloneRepository):
            openRepoSheet(.clone)
        case .action(.newRepository):
            openRepoSheet(.newRepository)
        case .action(.stashAll):
            requestStashAll()
        case .action(.searchAllRepositories):
            isPresented = false
            onRequestWorkspaceSearch()
        case .action:
            break // unreachable: every action without a repository step is handled above
        case .allRepositories:
            guard let pendingAction else { return }
            if pendingAction == .pushSelected {
                requestPushAll()
            } else {
                isPresented = false
                Task { await performAll(pendingAction) }
            }
        case .repository(let entry):
            guard let store = workspace.repositories.first(where: { $0.id.path == entry.id }) else { return }
            // No action picked: a repository row means "go to this repository".
            guard let pendingAction else {
                workspace.selectedRepoID = store.id
                isPresented = false
                return
            }
            if pendingAction.needsBranchStep {
                enterBranchStep(pendingAction, store: store)
            } else {
                runRepositoryAction(pendingAction, on: store)
            }
        case .branch(let entry):
            guard let pendingAction, let store = pendingBranchStepRepo else { return }
            switch pendingAction {
            case .mergeBranch:
                isPresented = false
                MergeRunner.run(branch: entry.name, on: store, toasts: toasts)
            case .deleteBranch:
                pendingDeleteBranchTarget = entry
            case .rebaseOnto:
                isPresented = false
                onRequestRebase(entry.name, store)
            case .fetchFromRemote:
                isPresented = false
                Task {
                    let result = await store.fetch(from: entry.name)
                    toasts.post(Toast(remote: result, repo: store.repo.name))
                }
            case .setUpstream:
                isPresented = false
                Task { await UpstreamMenuItems.set(entry.name, repo: store, toasts: toasts) }
            case .removeFromGit:
                isPresented = false
                repoSheets?.active = .removeFromGit(store, [entry.name])
            default:
                break // unreachable: only `needsBranchStep` actions reach the branch step
            }
        }
    }

    /// Moves to the third step — unless the action can't run for this repository, which toasts
    /// why and closes (the rule for every palette action).
    private func enterBranchStep(_ pending: PaletteRows.TopLevelAction, store: RepositoryStore) {
        switch pending {
        case .rebaseOnto:
            if let blocker = RebasePlan.blocker(repo: store.repo, operation: store.operation) {
                return stop(.error(store.repo.name, detail: blocker))
            }
        case .setUpstream:
            if store.repo.isDetached {
                return stop(.info(store.repo.name, detail: "HEAD is detached — an upstream belongs to a branch. Check out a branch first."))
            }
            if !store.branches.contains(where: \.isRemote) {
                return stop(.info(store.repo.name, detail: "No remote branches — fetch first"))
            }
        case .removeFromGit:
            // ponytail: whole `ls-files` list, fuzzy-ranked per keystroke; cap it if huge repos lag.
            Task {
                trackedPaths = await store.trackedPaths()
                if trackedPaths.isEmpty {
                    stop(.info(store.repo.name, detail: "No tracked files"))
                } else {
                    pendingBranchStepRepo = store
                    query = ""
                }
            }
            return
        case .fetchFromRemote:
            // `remoteNames` is only loaded for the selected repository — load it for this one.
            Task {
                await store.refreshRemotes()
                if store.remoteNames.isEmpty {
                    stop(.info(store.repo.name, detail: "No remotes — add one in Remotes…"))
                } else {
                    pendingBranchStepRepo = store
                    query = ""
                }
            }
            return
        default:
            break
        }
        pendingBranchStepRepo = store
        query = ""
    }

    private func stop(_ toast: Toast) {
        isPresented = false
        toasts.post(toast)
    }

    /// Second step for every action that needs one repository and no branch.
    private func runRepositoryAction(_ pending: PaletteRows.TopLevelAction, on store: RepositoryStore) {
        let name = store.repo.name
        switch pending {
        case .undoLastCommit:
            pendingUndo = UndoCommitRunner.request(on: store, toasts: toasts)
            if pendingUndo == nil { isPresented = false }
        case .forcePush:
            isPresented = false
            remoteOps.requestForcePush(on: store, toasts: toasts)
        case .fetchSelected:
            isPresented = false
            Task { await remoteOps.requestFetch(on: store, toasts: toasts) }
        case .pullSelected:
            isPresented = false
            Task { await remoteOps.requestPull(on: store, toasts: toasts) }
        case .pushSelected:
            isPresented = false
            Task { await remoteOps.requestPush(on: store, toasts: toasts) }
        case .cleanUntracked:
            isPresented = false
            onRequestCleanPreview(store)
        case .compareWithMain:
            isPresented = false
            onRequestCompare(store)
        case .goToCommit:
            isPresented = false
            onRequestGoToCommit(store)
        case .showReflog:
            isPresented = false
            recovery?.showReflog(store)
        case .createBranchHere:
            guard store.repo.isDetached else {
                return stop(.info(name, detail: "HEAD isn't detached (you're on \(store.repo.branch ?? "a branch")). Use New Branch in the branch menu, or Create Branch Here… on a commit in History."))
            }
            isPresented = false
            recovery?.requestCreateBranch(store, at: nil, shortHash: String((store.repo.headOID ?? "").prefix(7)))
        case .stashWithMessage:
            guard store.repo.hasChanges else { return stop(.info(name, detail: "Nothing to stash — no changes")) }
            guard !store.isBusy else { return stop(.info(name, detail: "Busy — try again in a moment")) }
            stashMessageTarget = store // closes the palette when answered
        case .showStashes:
            isPresented = false
            let sheets = repoSheets
            Task {
                await store.refreshStashCount()
                if store.stashCount == 0 { toasts.post(.info(name, detail: "No stashes")) } else { sheets?.active = .stashes(store) }
            }
        case .tags:
            openRepoSheet(.tags(store))
        case .deleteMergedBranches:
            openRepoSheet(.mergedCleanup(store))
        case .pushAllTags:
            Task {
                await store.refreshTags()
                guard !store.gitTags.isEmpty else { return stop(.info(name, detail: "No tags to push")) }
                pendingPushAllTags = PendingPushAllTags(store: store, tags: store.gitTags, remote: await store.tagRemote())
            }
        case .createTag:
            isPresented = false
            let sheets = repoSheets
            Task {
                guard let hash = await store.headHash(), let head = await store.commitInfo(hash) else {
                    return toasts.post(.info(name, detail: "No commits yet — nothing to tag"))
                }
                sheets?.active = .createTag(store, head)
            }
        case .remotes:
            openRepoSheet(.remotes(store))
        case .unsetUpstream:
            if store.repo.isDetached { return stop(.info(name, detail: "HEAD is detached — there's no branch upstream to unset")) }
            guard store.hasUpstream else { return stop(.info(name, detail: "\(store.repo.branch ?? "This branch") has no upstream")) }
            isPresented = false
            Task { await UpstreamMenuItems.unset(repo: store, toasts: toasts) }
        case .worktrees:
            isPresented = false
            repoSheets?.active = .worktrees(store)
        case .submodules:
            isPresented = false
            repoSheets?.active = .submodules(store)
        case .updateSubmodules:
            pendingUpdateSubmodules = store
        case .markReviewed:
            guard let head = store.repo.headOID else { return stop(.info(name, detail: "No commits yet — nothing to review")) }
            store.markReviewed()
            stop(.success(name, detail: "Marked reviewed up to \(head.prefix(7))"))
        case .gitConfig:
            openRepoSheet(.config(store))
        case .hooks:
            openRepoSheet(.hooks(store))
        case .createPullRequest, .openPullRequest:
            guard GHRunner.isAvailable else { return stop(.info(name, detail: GHError.notInstalled.localizedDescription)) }
            Task {
                let pr = await store.refreshPullRequest()
                guard store.pullRequestsSupported else { return stop(.info(name, detail: "origin isn't a GitHub remote")) }
                guard pending == .openPullRequest else { return pullRequestTarget = store } // closes the palette on dismiss
                guard let url = pr.flatMap({ URL(string: $0.url) }) else {
                    return stop(.info(name, detail: store.lastGHError ?? "No pull request for \(store.repo.branch ?? "this branch")"))
                }
                isPresented = false
                NSWorkspace.shared.open(url)
            }
        case .sparseCheckout:
            openRepoSheet(.sparseCheckout(store))
        case .tidyCommits:
            openRepoSheet(.interactiveRebase(store))
        case .applyPatch:
            openRepoSheet(.applyPatch(store, ""))
        case .rewordHead:
            if let op = store.operation { return stop(.info(name, detail: "A \(op.label) is in progress")) }
            if store.repo.isDetached || store.repo.headOID == nil { return stop(.info(name, detail: "No branch commit to reword")) }
            openRepoSheet(.rewordHead(store))
        case .copyDiffAsPatch:
            isPresented = false
            Task { await PatchExport.copyDiff(from: store, toasts: toasts) }
        case .startBisect:
            if let op = store.operation { return stop(.info(name, detail: "A \(op.label) is in progress")) }
            openRepoSheet(.startBisect(store))
        case .bisectGood, .bisectBad, .bisectSkip, .bisectReset:
            guard store.operation == .bisect else { return stop(.info(name, detail: "No bisect in progress")) }
            isPresented = false
            let verdict: BisectVerdict? = pending == .bisectGood ? .good : pending == .bisectBad ? .bad : pending == .bisectSkip ? .skip : nil
            Task {
                if let verdict { await BisectRunner.mark(verdict, on: store, toasts: toasts) } else { await BisectRunner.reset(store, toasts: toasts) }
            }
        default:
            break // unreachable: actions without a repository step run from `run`
        }
    }

    private func openRepoSheet(_ sheet: RepoSheets.Sheet) {
        isPresented = false
        repoSheets?.active = sheet
    }

    func confirmPushAllTags() {
        guard let pending = pendingPushAllTags else { return }
        pendingPushAllTags = nil
        isPresented = false
        Task {
            if await pending.store.pushAllTags() {
                toasts.post(.success("Pushed all tags to \(pending.remote ?? "the remote")", detail: pending.store.repo.name))
            }
        }
    }

    func confirmUpdateSubmodules() {
        guard let store = pendingUpdateSubmodules else { return }
        pendingUpdateSubmodules = nil
        isPresented = false
        Task {
            if let error = await store.updateSubmodules() {
                let message = RepoURL.redactingCredentials(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                toasts.post(.error(store.repo.name, detail: "Submodule update failed", stderr: message))
            } else {
                toasts.post(.success(store.repo.name, detail: "Submodules updated"))
            }
        }
    }

    /// No force-delete retry here: a "not fully merged" refusal is toasted by the `lastError`
    /// watcher; the override lives in the toolbar's branch submenu.
    func confirmDeleteBranch() {
        guard let entry = pendingDeleteBranchTarget, let store = pendingBranchStepRepo else { return }
        pendingDeleteBranchTarget = nil
        isPresented = false
        Task {
            let result = await store.deleteBranch(entry.name)
            if result.succeeded {
                toasts.post(.success(store.repo.name, detail: "Deleted \(entry.name)"))
            }
        }
    }

    /// Always listed; with no file open it says so rather than doing nothing.
    private func openInEditor() {
        guard let repo = workspace.selectedRepository, let path = currentFilePath else {
            toasts.post(.info("No file open", detail: "Select a file to open it in your editor"))
            return
        }
        editorRequests.open(repo.url.appendingPathComponent(path), configuredBundleID: workspace.config.settings.editorBundleID)
    }

    private func requestFileHistoryFromPalette() {
        isPresented = false
        guard let path = currentFilePath else {
            toasts.post(.info("No file open", detail: "Select a file to see its history"))
            return
        }
        onRequestFileHistory(path)
    }

    /// Reverting needs the commit reachable from HEAD, which isn't known here until asked; the
    /// palette stays open while that check runs.
    private func requestRevert() {
        guard let repo = workspace.selectedRepository, let commit = selectedCommit else {
            isPresented = false
            toasts.post(.info("No commit selected", detail: "Select a commit in History to revert it"))
            return
        }
        Task {
            guard await repo.isAncestorOfHead(commit.hash) else {
                isPresented = false
                toasts.post(.info("Not on this branch", detail: "\(commit.subject) isn't reachable from HEAD — try Cherry-pick instead"))
                return
            }
            pendingRevert = commit
        }
    }

    /// Mirror of `requestRevert` for the opposite eligibility check.
    private func requestCherryPick() {
        guard let repo = workspace.selectedRepository, let commit = selectedCommit else {
            isPresented = false
            toasts.post(.info("No commit selected", detail: "Select a commit in History to cherry-pick it"))
            return
        }
        Task {
            guard await !repo.isAncestorOfHead(commit.hash) else {
                isPresented = false
                toasts.post(.info("Already on this branch", detail: "\(commit.subject) is already reachable from HEAD — try Revert instead"))
                return
            }
            pendingCherryPick = commit
        }
    }

    /// Same skip rules as `WorkspaceStore.pushAll`, from state in memory, so the confirmation can
    /// name the real count without shelling out to git.
    private var pushAllCandidates: [RepositoryStore] {
        workspace.repositories.filter { $0.repo.isAvailable && $0.hasUpstream && $0.repo.ahead > 0 }
    }

    var pushAllConfirmTitle: String {
        let n = pushAllCandidates.count
        return "Push \(n) repositor\(n == 1 ? "y" : "ies")?"
    }

    var pushAllConfirmDetail: String {
        let branches = Set(pushAllCandidates.compactMap(\.repo.branch)).sorted()
        if branches.count == 1, let branch = branches.first {
            return "This pushes the current branch (\(branch)) in every listed repository. Repositories with no upstream or nothing to push are skipped."
        }
        return "This pushes the current branch in every listed repository. Repositories with no upstream or nothing to push are skipped."
    }

    private func requestPushAll() {
        guard !pushAllCandidates.isEmpty else {
            toasts.post(.info("Nothing to push", detail: "No repository has commits ready to push"))
            return
        }
        pendingPushAllConfirm = true
    }

    var stashAllCandidates: [RepositoryStore] {
        workspace.repositories.filter { $0.repo.isAvailable && !WorkspaceStore.skipsStash($0) }
    }

    private func requestStashAll() {
        guard !stashAllCandidates.isEmpty else {
            isPresented = false
            toasts.post(.info("Nothing to stash", detail: "No repository has uncommitted changes"))
            return
        }
        pendingStashAllConfirm = true
    }

    func confirmStashAll() {
        pendingStashAllConfirm = false
        isPresented = false
        Task {
            if let running = workspace.bulk {
                return toasts.post(.info("A \(running.kind.rawValue) is already running", detail: "\(running.completed) of \(running.total) done"))
            }
            RemoteActionRunner.postBulkResult(await workspace.stashAll(), kind: "Stashed", toasts: toasts)
        }
    }

    func confirmPushAll() {
        pendingPushAllConfirm = false
        isPresented = false
        Task { await performAll(.pushSelected) }
    }

    /// "All repositories" — only reachable when `offersAll`; push is confirmed first.
    private func performAll(_ pending: PaletteRows.TopLevelAction) async {
        if let running = workspace.bulk {
            toasts.post(.info("A \(running.kind.rawValue) is already running",
                              detail: "\(running.completed) of \(running.total) done"))
            return
        }
        switch pending {
        case .fetchSelected:
            let op = await workspace.fetchAll()
            RemoteActionRunner.postBulkResult(op, kind: "Fetched", toasts: toasts)
        case .pullSelected:
            let op = await workspace.pullAll()
            RemoteActionRunner.postBulkResult(op, kind: "Pulled", toasts: toasts)
        case .pushSelected:
            let flagged = await RepositoryStore.flaggedForSecrets(in: pushAllCandidates)
            if !flagged.isEmpty {
                toasts.post(.info("Skipped \(flagged.count) repositor\(flagged.count == 1 ? "y" : "ies") with possible secrets",
                                  detail: "Push them individually to review"))
            }
            let op = await workspace.pushAll(excluding: flagged)
            RemoteActionRunner.postBulkResult(op, kind: "Pushed", toasts: toasts)
        default:
            preconditionFailure("\(pending.chipLabel) doesn't offer an All row")
        }
    }
}
