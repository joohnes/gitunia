import SwiftUI
import GituniaCore

/// Everything `ResetSheet` needs, resolved before it opens so the sheet itself is plain values.
struct ResetPlan: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    let branch: String
    let targetHash: String
    let targetShortHash: String
    let targetSubject: String
    /// HEAD when the plan was made — `reset(expectedHead:)` refuses if an agent moved it since.
    let headAtRequest: String?
    let impact: ResetImpact
    let warnings: [PreflightIssue]
    let lostFiles: [String]
}

struct PendingCommitCheckout: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    let hash: String
    let shortHash: String
    let subject: String
    let blockers: [PreflightIssue]
    /// Only the "uncommitted" blocker — stashing fixes that, not unresolved conflicts.
    var canStash: Bool { blockers.map(\.id) == ["uncommitted"] }
}

/// Restoring a Gitunia stash made on `branch` while another branch is checked out.
struct PendingStashRestore: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    let item: StashItem
    let branch: String
    let pop: Bool
}

struct PendingLeaveDetached: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    let issue: PreflightIssue
    let proceed: @MainActor () async -> Void
}

/// `hash == nil` means "attach the detached HEAD" (`git checkout -b`); otherwise the branch is
/// created at `hash` without switching (`git branch <name> <hash>`).
struct PendingCreateBranch: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    let hash: String?
    let shortHash: String
}

/// Reflog / reset / detached-HEAD flows, shared by History's context menu, the branch menu, the
/// reflog sheet and ⌘K. Lives in `ContentView` and reaches the rest through the environment
/// (optional there, so views rendered without it — tests — just hide these actions).
@MainActor
@Observable
final class RecoveryCoordinator {
    var reflogStore: RepositoryStore?
    var pendingReset: ResetPlan?
    var pendingCheckout: PendingCommitCheckout?
    var pendingLeaveDetached: PendingLeaveDetached?
    var pendingCreateBranch: PendingCreateBranch?
    var pendingStashRestore: PendingStashRestore?
    var newBranchName = ""

    func showReflog(_ store: RepositoryStore) { reflogStore = store }

    func requestCreateBranch(_ store: RepositoryStore, at hash: String?, shortHash: String) {
        newBranchName = ""
        pendingCreateBranch = PendingCreateBranch(store: store, hash: hash, shortHash: shortHash)
    }

    /// Preflight, then the reset sheet. Blockers (detached HEAD, an operation in progress) toast
    /// and stop — nothing to override.
    func requestReset(_ store: RepositoryStore, to hash: String, shortHash: String, subject: String, toasts: ToastCenter) async {
        let impact = await store.resetImpact(to: hash)
        let issues = Preflight.checkReset(repo: store.repo, operation: store.operation, impact: impact)
        if let blocker = issues.first(where: { $0.severity == .blocker }) {
            toasts.post(.error(store.repo.name, detail: blocker.message))
            return
        }
        pendingReset = ResetPlan(
            store: store, branch: store.repo.branch ?? "HEAD", targetHash: hash, targetShortHash: shortHash,
            targetSubject: subject, headAtRequest: await store.headHash(), impact: impact,
            warnings: issues, lostFiles: store.repo.filesLostByHardReset)
    }

    func performReset(_ plan: ResetPlan, mode: ResetMode, toasts: ToastCenter) {
        pendingReset = nil
        Task {
            guard await plan.store.reset(to: plan.targetHash, mode: mode, expectedHead: plan.headAtRequest) else { return }
            toasts.post(.success("Reset \(plan.branch) to \(plan.targetShortHash) (\(mode.rawValue))",
                                 detail: plan.impact.undone > 0 ? "Undone commits are still in the Reflog" : nil))
        }
    }

    func requestCheckoutCommit(_ store: RepositoryStore, hash: String, shortHash: String, subject: String) {
        guardLeavingDetached(store) { [self] in
            let blockers = Preflight.check(.checkout(branch: shortHash), repo: store.repo, hasUpstream: store.hasUpstream)
                .filter { $0.severity == .blocker }
            pendingCheckout = PendingCommitCheckout(store: store, hash: hash, shortHash: shortHash, subject: subject, blockers: blockers)
        }
    }

    func performCheckout(_ pending: PendingCommitCheckout, stashFirst: Bool, toasts: ToastCenter) {
        pendingCheckout = nil
        Task {
            if stashFirst {
                guard await pending.store.stash(message: pending.store.stashLabel(for: pending.store.repo.branch ?? "HEAD")) else { return }
            }
            guard await pending.store.checkoutDetached(pending.hash) else { return }
            toasts.post(.info(pending.store.repo.name, detail: "Detached at \(pending.shortHash)"
                              + (stashFirst ? " — your changes are stashed" : "")))
        }
    }

    /// Runs `proceed` unless HEAD is detached with commits no branch has — then asks first, offering
    /// Create Branch Here. Every "switch away" path (branch checkout, commit checkout) goes through it.
    func guardLeavingDetached(_ store: RepositoryStore, proceed: @escaping @MainActor () async -> Void) {
        Task {
            guard store.repo.isDetached,
                  let issue = Preflight.checkLeavingDetachedHead(repo: store.repo, orphanCount: await store.commitsOnlyOnHead())
            else { await proceed(); return }
            pendingLeaveDetached = PendingLeaveDetached(store: store, issue: issue, proceed: proceed)
        }
    }

    /// Same branch: apply/pop right away. Another branch: ask (Apply Here / Switch then Apply).
    func requestStashRestore(_ store: RepositoryStore, item: StashItem, pop: Bool, toasts: ToastCenter) {
        let branch = item.gituniaLabel?.branch ?? item.entry.branch
        if branch.isEmpty || branch == store.repo.branch {
            restoreStash(store, item: item, pop: pop, toasts: toasts)
        } else {
            pendingStashRestore = PendingStashRestore(store: store, item: item, branch: branch, pop: pop)
        }
    }

    func restoreStash(_ store: RepositoryStore, item: StashItem, pop: Bool, toasts: ToastCenter) {
        Task {
            switch await store.stashApply(item, pop: pop) {
            case .applied:
                toasts.post(.success(store.repo.name, detail: pop ? "Restored the stashed changes" : "Applied the stashed changes — the stash is kept"))
            case .conflicts(let n):
                toasts.post(.info(store.repo.name, detail: "\(n) file\(n == 1 ? "" : "s") conflicted — the stash was kept"))
            case .failed:
                break // `lastError` is set; ContentView's error watcher toasts it.
            }
        }
    }

    /// Switches through the normal checkout path — detached-HEAD guard and preflight; any blocker
    /// (e.g. the tree is dirty) toasts and stops rather than being overridden from here.
    func switchThenRestore(_ pending: PendingStashRestore, toasts: ToastCenter) {
        pendingStashRestore = nil
        let store = pending.store
        guardLeavingDetached(store) { [self] in
            if let blocker = Preflight.check(.checkout(branch: pending.branch), repo: store.repo, hasUpstream: store.hasUpstream,
                                             operationInProgress: store.operation != nil).first(where: { $0.severity == .blocker }) {
                toasts.post(.error(store.repo.name, detail: blocker.message))
                return
            }
            guard await store.checkout(BranchInfo(name: pending.branch, isCurrent: false, isRemote: false)) else { return }
            restoreStash(store, item: pending.item, pop: pending.pop, toasts: toasts)
        }
    }

    func performCreateBranch(_ pending: PendingCreateBranch, toasts: ToastCenter) {
        let name = RepositoryStore.branchName(fromInput: newBranchName)
        pendingCreateBranch = nil
        newBranchName = ""
        guard !name.isEmpty else { return }
        Task {
            let ok = if let hash = pending.hash {
                await pending.store.createBranch(name, at: hash)
            } else {
                await pending.store.createBranch(name)
            }
            if ok { toasts.post(.success("Created branch \(name)", detail: "at \(pending.shortHash)")) }
        }
    }
}

/// The recovery dialogs, and the coordinator's environment entry. Applied twice: on `ContentView`
/// (which also hosts the reflog sheet) and inside the reflog sheet — a view presenting a sheet can't present a dialog over it, so the
/// outer copy stands down while the reflog is open.
struct RecoveryDialogs: ViewModifier {
    @Bindable var recovery: RecoveryCoordinator
    var hostsReflog: Bool
    @Environment(ToastCenter.self) private var toasts

    private var active: Bool { !hostsReflog || recovery.reflogStore == nil }

    private func presented<T>(_ keyPath: ReferenceWritableKeyPath<RecoveryCoordinator, T?>) -> Binding<Bool> {
        Binding(get: { active && recovery[keyPath: keyPath] != nil },
                set: { if !$0 { recovery[keyPath: keyPath] = nil } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { hostsReflog ? recovery.reflogStore : nil }, set: { recovery.reflogStore = $0 })) { store in
                ReflogSheet(store: store, onDone: { recovery.reflogStore = nil })
                    .modifier(RecoveryDialogs(recovery: recovery, hostsReflog: false))
                    .environment(toasts)
            }
            .sheet(item: Binding(get: { active ? recovery.pendingReset : nil }, set: { recovery.pendingReset = $0 })) { plan in
                ResetSheet(plan: plan,
                           onCancel: { recovery.pendingReset = nil },
                           onReset: { mode in recovery.performReset(plan, mode: mode, toasts: toasts) })
            }
            .confirmationDialog(
                "Check out \(recovery.pendingCheckout?.shortHash ?? "commit")?",
                isPresented: presented(\.pendingCheckout), titleVisibility: .visible
            ) {
                if let pending = recovery.pendingCheckout {
                    if pending.canStash {
                        Button("Stash and Check Out") { recovery.performCheckout(pending, stashFirst: true, toasts: toasts) }
                    }
                    Button(pending.blockers.isEmpty ? "Check Out" : "Check Out Anyway", role: pending.blockers.isEmpty ? nil : .destructive) {
                        recovery.performCheckout(pending, stashFirst: false, toasts: toasts)
                    }
                }
                Button("Cancel", role: .cancel) { recovery.pendingCheckout = nil }
            } message: {
                Text(recovery.pendingCheckout.map(Self.checkoutMessage) ?? "")
            }
            .confirmationDialog(
                "Leave commits behind?",
                isPresented: presented(\.pendingLeaveDetached), titleVisibility: .visible
            ) {
                if let pending = recovery.pendingLeaveDetached {
                    Button("Create Branch Here…") {
                        recovery.pendingLeaveDetached = nil
                        recovery.requestCreateBranch(pending.store, at: nil, shortHash: String((pending.store.repo.headOID ?? "").prefix(7)))
                    }
                    Button("Switch Anyway", role: .destructive) {
                        recovery.pendingLeaveDetached = nil
                        Task { await pending.proceed() }
                    }
                }
                Button("Cancel", role: .cancel) { recovery.pendingLeaveDetached = nil }
            } message: {
                Text(recovery.pendingLeaveDetached?.issue.message ?? "")
            }
            .confirmationDialog(
                "This stash was made on \(recovery.pendingStashRestore?.branch ?? "another branch"). Apply it here on \(recovery.pendingStashRestore?.store.repo.branchLabel ?? "the current branch")?",
                isPresented: presented(\.pendingStashRestore), titleVisibility: .visible
            ) {
                if let pending = recovery.pendingStashRestore {
                    Button("Apply Here") {
                        recovery.pendingStashRestore = nil
                        recovery.restoreStash(pending.store, item: pending.item, pop: pending.pop, toasts: toasts)
                    }
                    Button("Switch to \(pending.branch) then Apply") { recovery.switchThenRestore(pending, toasts: toasts) }
                }
                Button("Cancel", role: .cancel) { recovery.pendingStashRestore = nil }
            }
            .alert("Create Branch at \(recovery.pendingCreateBranch?.shortHash ?? "HEAD")", isPresented: presented(\.pendingCreateBranch)) {
                TextField("Branch name", text: $recovery.newBranchName)
                Button("Create") { if let pending = recovery.pendingCreateBranch { recovery.performCreateBranch(pending, toasts: toasts) } }
                Button("Cancel", role: .cancel) { recovery.pendingCreateBranch = nil }
            } message: {
                Text(recovery.pendingCreateBranch?.hash == nil
                     ? "Creates the branch at the detached HEAD and switches to it, so its commits are kept."
                     : "Creates the branch at this commit. You stay on your current branch.")
            }
            // Everything the modifier wraps (toolbar, History, the reflog sheet) reaches the
            // coordinator through the environment.
            .environment(recovery)
    }

    static func checkoutMessage(_ pending: PendingCommitCheckout) -> String {
        var lines = ["\"\(pending.subject)\" — you'll be in detached HEAD: looking at this commit directly, on no branch. Commits you make there need a branch to be kept."]
        lines += pending.blockers.map(\.message)
        return lines.joined(separator: "\n\n")
    }
}

/// History header / branch menu entry point.
struct ReflogButton: View {
    var repo: RepositoryStore
    @Environment(RecoveryCoordinator.self) private var recovery: RecoveryCoordinator?

    var body: some View {
        if let recovery {
            Button { recovery.showReflog(repo) } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
                .help("Reflog — every place HEAD has been; recover reset or rebased-away commits")
        }
    }
}
