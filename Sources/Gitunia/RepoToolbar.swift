import SwiftUI
import GituniaCore

/// A blocker-level preflight result awaiting the user's decision, surfaced as a confirmation
/// dialog. `ToolbarContent` can't host a `.confirmationDialog` itself, so this state lives in
/// `ContentView` (the toolbar's host) and is handed down by binding; `action` is the git call to
/// run if the user overrides the blockers.
struct PendingToolbarConfirmation: Identifiable {
    let id = UUID()
    let issues: [PreflightIssue]
    let action: () async -> Void
    /// Non-nil only when this confirmation is a checkout blocked solely by the "uncommitted
    /// changes will follow you" blocker (not also blocked by unresolved conflicts, which stashing
    /// does nothing for) — set by `RepoToolbarContent.runWithPreflight` by checking the
    /// `PreflightAction` case and `PreflightIssue.id`, never by matching message text. Carries the
    /// target branch name so the confirmation dialog can offer "Stash and switch" and word its
    /// follow-up toast.
    let stashAndSwitchTarget: String?
}

struct RepoToolbarContent: ToolbarContent {
    var repo: RepositoryStore
    @Binding var showNewBranch: Bool
    @Binding var pendingConfirmation: PendingToolbarConfirmation?
    @Binding var pendingBranchVerb: PendingBranchVerb?
    @Binding var pendingRebase: PendingRebase?
    @Environment(ToastCenter.self) private var toasts
    @Environment(RemoteOpsCoordinator.self) private var remoteOps
    @Environment(RecoveryCoordinator.self) private var recovery: RecoveryCoordinator?
    @Environment(RepoSheets.self) private var repoSheets: RepoSheets?
    @State private var showBranchPicker = false
    /// The popover lists remote branches to pick an upstream from instead of switching branches.
    @State private var pickingUpstream = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Click = the searchable branch popover; the menu arrow = the repository-level items.
            // Branches used to be nested submenus right here — one `NSMenuItem` subtree per branch,
            // rebuilt on every repository change, which stalled with thousands of branches.
            Menu {
                if let recovery, repo.repo.isDetached {
                    Section(repo.repo.branchLabel) {
                        Button("Create Branch Here…", systemImage: "plus") {
                            recovery.requestCreateBranch(repo, at: nil, shortHash: String((repo.repo.headOID ?? "").prefix(7)))
                        }
                    }
                }
                Button("Switch Branch…", systemImage: "arrow.triangle.branch") { pickingUpstream = false; showBranchPicker = true }
                Button("New Branch…", systemImage: "plus") { showNewBranch = true }
                if let recovery {
                    Button("Reflog…", systemImage: "clock.arrow.circlepath") { recovery.showReflog(repo) }
                }
                Button("Tags…", systemImage: "tag") { repoSheets?.active = .tags(repo) }
                Button("Delete Merged Branches…", systemImage: "arrow.triangle.merge") { repoSheets?.active = .mergedCleanup(repo) }
                Button("Tidy Commits…", systemImage: "wand.and.stars") { repoSheets?.active = .interactiveRebase(repo) }
                Divider()
                UpstreamMenuItems(repo: repo, toasts: toasts) { pickingUpstream = true; showBranchPicker = true }
                Button("Remotes…", systemImage: "network") { repoSheets?.active = .remotes(repo) }
                Button("Git Config…", systemImage: "gearshape.2") { repoSheets?.active = .config(repo) }
                Button(repo.hasActiveHooks ? "Hooks… (\(repo.activeHookCount) active)" : "Hooks…", systemImage: "bolt") { repoSheets?.active = .hooks(repo) }
                Button("Sparse Checkout…", systemImage: "square.dashed.inset.filled") { repoSheets?.active = .sparseCheckout(repo) }
            } label: {
                Label(repo.repo.branchLabel, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
            } primaryAction: {
                pickingUpstream = false
                showBranchPicker = true
            }
            .popover(isPresented: $showBranchPicker, arrowEdge: .bottom) {
                if pickingUpstream {
                    BranchListPopover(
                        branches: repo.branches.filter(\.isRemote),
                        selection: repo.upstreamRemote.flatMap { remote in repo.upstreamBranch.map { "\(remote)/\($0)" } },
                        onPick: { name in closingBranchPicker { Task { await UpstreamMenuItems.set(name, repo: repo, toasts: toasts) } } }
                    )
                } else {
                    BranchListPopover(
                        branches: repo.branches,
                        selection: repo.repo.branch,
                        selectionIsPickable: false,
                        onPick: { name in
                            guard let branch = repo.branches.first(where: { $0.name == name }) else { return }
                            closingBranchPicker { checkout(branch) }
                        },
                        rowMenu: { branch in
                            Group {
                                if branch.isRemote { remoteBranchMenuItems(branch) } else { localBranchMenuItems(branch) }
                            }
                        }
                    )
                }
            }
            .help(repo.unreviewedCount.map { "Switch branch — \($0) unreviewed commit\($0 == 1 ? "" : "s")" } ?? "Switch branch")
            .disabled(repo.isBusy)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await repo.fetch() }
            } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
            }
            .help("git fetch --prune")
            .disabled(repo.isBusy)

            Button {
                Task { await remoteOps.requestPull(on: repo, toasts: toasts) }
            } label: {
                Label(repo.repo.behind > 0 ? "Pull ↓\(repo.repo.behind)" : "Pull", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("git pull --ff-only")
            .disabled(!repo.hasUpstream || repo.isBusy)

            Button {
                Task { await remoteOps.requestPush(on: repo, toasts: toasts) }
            } label: {
                Label(repo.repo.ahead > 0 ? "Push ↑\(repo.repo.ahead)" : "Push", systemImage: "arrow.up.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help(repo.hasUpstream ? "git push" : "git push -u \(RemoteSelection.pushRemote(from: repo.remoteNames, preferred: repo.defaultRemote) ?? "origin") HEAD")
            .disabled(repo.isBusy)

            PullRequestToolbarButton(repo: repo)

            Menu {
                Button("Force Push…", systemImage: "exclamationmark.triangle") {
                    remoteOps.requestForcePush(on: repo, toasts: toasts)
                }
                .disabled(repo.isBusy || !repo.hasUpstream)
                FetchFromMenu(repo: repo, toasts: toasts)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("More actions")
            .disabled(repo.isBusy)
        }
    }

    /// Blockers interrupt with a confirmation dialog (destructive "Do it anyway" override);
    /// warnings post an info toast and proceed. Mirrors `SidebarView.runRemote`'s checks, but a
    /// toolbar press is a decision (dialog + override) where a hover button is a glance (toast only).
    private func runWithPreflight(_ action: PreflightAction, _ run: @escaping () async -> Void) {
        let issues = Preflight.check(action, repo: repo.repo, hasUpstream: repo.hasUpstream, operationInProgress: repo.operation != nil)
        let blockers = issues.filter { $0.severity == .blocker }
        if !blockers.isEmpty {
            var stashTarget: String?
            if case .checkout(let branch) = action,
               blockers.contains(where: { $0.id == "uncommitted" }),
               !blockers.contains(where: { $0.id == "conflicted" }) {
                stashTarget = branch
            }
            pendingConfirmation = PendingToolbarConfirmation(issues: blockers, action: run, stashAndSwitchTarget: stashTarget)
            return
        }
        for warning in issues where warning.severity == .warning {
            toasts.post(.info(repo.repo.name, detail: warning.message))
        }
        Task { await run() }
    }

    /// Switching away from a detached HEAD with commits on no branch asks first (see
    /// `RecoveryCoordinator.guardLeavingDetached`).
    private func leavingDetachedHead(_ proceed: @escaping @MainActor () -> Void) {
        guard let recovery else { return proceed() }
        recovery.guardLeavingDetached(repo) { proceed() }
    }

    // MARK: - Branch popover

    private func checkout(_ branch: BranchInfo) {
        leavingDetachedHead { runWithPreflight(.checkout(branch: branch.name)) { _ = await repo.checkout(branch) } }
    }

    /// Every popover action closes the popover first and acts a runloop turn later, so the dialogs
    /// `ContentView` presents (preflight, branch verbs, rebase, leaving detached HEAD) never race a
    /// popover that's still on screen.
    private func closingBranchPicker(_ action: @escaping @MainActor () -> Void) {
        showBranchPicker = false
        DispatchQueue.main.async { action() }
    }

    /// Row context menu. The current branch's offers Rename only — you can't merge or delete a
    /// branch you have checked out. Rather than disabling Merge/Delete with an explanatory `.help`
    /// (easy to miss, and this is impossible, not merely inadvisable right now), they're omitted
    /// outright and Checkout stays disabled the way the flat list already did.
    @ViewBuilder
    private func localBranchMenuItems(_ branch: BranchInfo) -> some View {
        Button("Checkout") {
            closingBranchPicker { checkout(branch) }
        }
        .disabled(branch.isCurrent)

        if !branch.isCurrent {
            Button("Merge into \(repo.repo.branch ?? "current")") {
                closingBranchPicker { MergeRunner.run(branch: branch.name, on: repo, toasts: toasts) }
            }
            Button("Rebase \(repo.repo.branch ?? "current") onto \(branch.name)…") {
                closingBranchPicker { RebaseOntoRunner.request(onto: branch.name, on: repo, toasts: toasts, pending: $pendingRebase) }
            }
        }

        Button("Rename…") { closingBranchPicker { pendingBranchVerb = .rename(branch: branch.name) } }

        if !branch.isCurrent {
            Button("Delete…", role: .destructive) {
                closingBranchPicker { pendingBranchVerb = .delete(branch: branch.name, forceRetry: false, refusalMessage: nil) }
            }
        }
    }

    private func remoteBranchMenuItems(_ branch: BranchInfo) -> some View {
        let (remote, shortName) = splitRemoteBranchName(branch.name)
        return Group {
            Button("Checkout") {
                closingBranchPicker { checkout(branch) }
            }
            Button("Merge into \(repo.repo.branch ?? "current")") {
                closingBranchPicker { MergeRunner.run(branch: branch.name, on: repo, toasts: toasts) }
            }
            Button("Rebase \(repo.repo.branch ?? "current") onto \(branch.name)…") {
                closingBranchPicker { RebaseOntoRunner.request(onto: branch.name, on: repo, toasts: toasts, pending: $pendingRebase) }
            }
            Button("Delete on Remote…", role: .destructive) {
                closingBranchPicker { pendingBranchVerb = .remoteDelete(remote: remote, branch: shortName) }
            }
        }
    }

    /// `"origin/feat/x"` → `("origin", "feat/x")` — same split `checkout(_:)` already does for a
    /// remote `BranchInfo`'s tracking-branch name.
    private func splitRemoteBranchName(_ name: String) -> (remote: String, branch: String) {
        let parts = name.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return ("origin", name) }
        return (String(parts[0]), String(parts[1]))
    }
}
