import SwiftUI
import GituniaCore

/// Every single-repository Pull/Push (and force-push) in the app funnels through here, so the
/// diverged-pull choice and the force-push confirmation are the same dialog no matter which of the
/// several call sites triggered them — sidebar hover button, sidebar context menu, window toolbar,
/// ⌘⇧L/⌘⇧P, and the ⌘K palette. `ContentView` hosts the two dialogs (`.confirmationDialog`, driven
/// by `pendingDivergedPull`/`pendingForcePush`) since it's a common ancestor of every one of those
/// call sites; everything else here just posts toasts, same pattern as `RemoteActionRunner`.
@MainActor
@Observable
final class RemoteOpsCoordinator {
    /// Set when `Preflight.isDiverged` (or a live `pull --ff-only` failure classified as `.diverged`)
    /// means a plain pull can't succeed — `ContentView` shows the rebase/merge/cancel choice.
    var pendingDivergedPull: RepositoryStore?
    /// Set once force push has passed its preflight blocker check — `ContentView` shows the
    /// confirmation naming the branch and remote before anything destructive runs.
    var pendingForcePush: PendingForcePush?
    /// Set when a push finds no remote at all — `ContentView` asks for a URL to add as "origin",
    /// then pushes again (`addOriginAndPush`).
    var pendingAddRemote: RepositoryStore?
    /// Set when the commits a push would send add secret-looking lines — `ContentView` lists them
    /// and "Push Anyway" runs `proceed`. Agents can commit on their own, skipping CommitBox's scan.
    var pendingPushSecrets: (store: RepositoryStore, findings: [SecretScanner.Finding], proceed: @MainActor () async -> Void)?

    /// M8: set once by `ContentView` (`.onAppear`) — the only reason this coordinator needs a
    /// `WorkspaceStore` reference at all is so the rejected-push toast's "Force push…" action
    /// (below) can check, at the moment the user actually clicks it, that the `RepositoryStore` it
    /// captured is still one of `workspace.repositories` — a toast can outlive the workspace it was
    /// posted for if the user opens a different folder before dismissing it. `weak` since this
    /// coordinator is a long-lived environment object and must never keep the workspace alive.
    weak var workspace: WorkspaceStore?

    /// The branch is captured when force push is requested (for a rejected-push toast: the branch
    /// whose push was rejected), not read again when the user confirms — the confirmation names it
    /// and `RepositoryStore.forcePush(branch:)` pushes exactly it, even if HEAD moved in between
    /// (the user switched branch, or an agent checked one out while the toast/dialog was up).
    struct PendingForcePush {
        let store: RepositoryStore
        let branch: String
    }

    func requestFetch(on store: RepositoryStore, toasts: ToastCenter) async {
        let result = await store.fetch()
        toasts.post(Toast(remote: result, repo: store.repo.name))
    }

    /// The one entry point every Pull trigger in the app calls. Checks blockers, then divergence
    /// (before ever running git — `pull --ff-only` on a diverged branch is a known dead end), then
    /// runs the plain pull; if git itself still rejects it as non-fast-forward (the ahead/behind
    /// counts were stale), falls back to the same choice dialog rather than just toasting the error.
    func requestPull(on store: RepositoryStore, toasts: ToastCenter) async {
        let issues = Preflight.check(.pull, repo: store.repo, hasUpstream: store.hasUpstream)
        if let blocker = issues.first(where: { $0.severity == .blocker }) {
            toasts.post(.error(store.repo.name, detail: blocker.message))
            return
        }
        if Preflight.isDiverged(repo: store.repo) {
            pendingDivergedPull = store
            return
        }
        if let warning = issues.first(where: { $0.severity == .warning }) {
            toasts.post(.info(store.repo.name, detail: warning.message))
        }
        let result = await store.pull()
        if !result.succeeded, result.failureKind == .diverged {
            pendingDivergedPull = store
            return
        }
        toasts.post(Toast(remote: result, repo: store.repo.name))
    }

    /// "Rebase my commits on top" — the first choice in the diverged-pull dialog.
    func runRebase(on store: RepositoryStore, toasts: ToastCenter) async {
        pendingDivergedPull = nil
        let result = await store.pullRebase()
        toasts.post(Toast(remote: result, repo: store.repo.name))
    }

    /// "Merge" — the second choice in the diverged-pull dialog.
    func runMerge(on store: RepositoryStore, toasts: ToastCenter) async {
        pendingDivergedPull = nil
        let result = await store.pullMerge()
        toasts.post(Toast(remote: result, repo: store.repo.name))
    }

    /// The one entry point every plain Push trigger calls. A rejection classified as
    /// non-fast-forward gets a "Force push…" action on its error toast instead of just failing —
    /// that's the whole reason force push needs to be discoverable from the ordinary push path, not
    /// only from its own menu items.
    func requestPush(on store: RepositoryStore, toasts: ToastCenter, secretsReviewed: Bool = false) async {
        if !secretsReviewed {
            let findings = await store.unpushedSecretFindings()
            if !findings.isEmpty {
                pendingPushSecrets = (store, findings, { [self] in await self.requestPush(on: store, toasts: toasts, secretsReviewed: true) })
                return
            }
        }
        // A renamed branch still tracking its old remote name isn't a real push upstream — its
        // `ahead` is against the old branch, and `push()` will set the new upstream anyway.
        let issues = Preflight.check(.push, repo: store.repo, hasUpstream: store.hasUpstream && store.upstreamMatchesBranch)
        for warning in issues where warning.severity == .warning {
            toasts.post(.info(store.repo.name, detail: warning.message))
        }
        let pushedBranch = store.repo.branch
        let result = await store.push()
        if result.failureKind == .noRemote {
            pendingAddRemote = store
            return
        }
        guard !result.succeeded, result.failureKind == .nonFastForward, let pushedBranch else {
            toasts.post(Toast(remote: result, repo: store.repo.name))
            return
        }
        toasts.post(.error(store.repo.name,
                            detail: Self.rejectedPushDetail(branch: pushedBranch),
                            stderr: result.error?.stderr,
                            command: result.error?.commandLine,
                            action: ToastAction(title: "Force push…") { [self] in
            Task { @MainActor in
                // M8: the toast can still be on screen after the user's opened a different
                // workspace — `workspace` being nil (never wired) fails open, same as before.
                guard self.workspace?.repositories.contains(where: { $0 === store }) ?? true else {
                    toasts.post(.error(store.repo.name, detail: "That repository is no longer open"))
                    return
                }
                self.requestForcePush(on: store, branch: pushedBranch, toasts: toasts)
            }
        }))
    }

    /// Runs after the user enters a URL in the add-remote prompt.
    func addOriginAndPush(on store: RepositoryStore, url: String, toasts: ToastCenter) async {
        pendingAddRemote = nil
        switch await store.addRemote(name: "origin", url: url) {
        case .succeeded:
            await requestPush(on: store, toasts: toasts)
        case .invalid(let message), .failed(let message):
            toasts.post(.error(store.repo.name, detail: "Couldn't add remote origin", stderr: message))
        }
    }

    /// "<short hash> <subject> — <path>: <kind>" per finding, never the matched value.
    /// Shared with `RebaseForcePushRenderTests` so the render shows the real wording.
    static func rejectedPushDetail(branch: String) -> String {
        "Push rejected — the remote has commits on \(branch) that you don't have. Pull first, or force push."
    }

    /// Checks force push's own preflight (blocker: no upstream) before opening the confirmation —
    /// a repo that can't be force-pushed at all should say why instead of opening an empty dialog.
    /// `branch` defaults to the current branch; the rejected-push toast passes the branch it was
    /// about. Preflight reads live repo state, so it only applies while that branch is current —
    /// otherwise `forcePush(branch:)` still refuses on its own if the branch has no upstream.
    func requestForcePush(on store: RepositoryStore, branch: String? = nil, toasts: ToastCenter) {
        guard let branch = branch ?? store.repo.branch else { return }
        let issues = branch == store.repo.branch ? Preflight.check(.forcePush, repo: store.repo, hasUpstream: store.hasUpstream) : []
        if let blocker = issues.first(where: { $0.severity == .blocker }) {
            toasts.post(.error(store.repo.name, detail: blocker.message))
            return
        }
        for warning in issues where warning.severity == .warning {
            toasts.post(.info(store.repo.name, detail: warning.message))
        }
        pendingForcePush = PendingForcePush(store: store, branch: branch)
    }

    /// Runs after the user confirms the force-push dialog. A lease rejection gets its own wording —
    /// "stale info" means someone else pushed since this repo's last fetch, so the honest next step
    /// is fetch-and-review, not "try again" (which would just fail the same way with `--force-with-
    /// lease`, or silently clobber the new remote commits with a bare `--force`, which this app
    /// never uses).
    func runForcePush(_ pending: PendingForcePush, toasts: ToastCenter, secretsReviewed: Bool = false) async {
        pendingForcePush = nil
        let store = pending.store
        // Scanned here, not in `requestForcePush` (sync, called from several views): after the
        // force confirmation, for exactly the branch it named.
        if !secretsReviewed {
            let findings = await store.unpushedSecretFindings(branch: pending.branch)
            if !findings.isEmpty {
                pendingPushSecrets = (store, findings, { [self] in await self.runForcePush(pending, toasts: toasts, secretsReviewed: true) })
                return
            }
        }
        let result = await store.forcePush(branch: pending.branch)
        if !result.succeeded, result.failureKind == .leaseStale {
            toasts.post(.error(store.repo.name,
                                detail: "The remote changed since your last fetch — fetch and review before forcing.",
                                stderr: result.error?.stderr, command: result.error?.commandLine))
        } else {
            toasts.post(Toast(remote: result, repo: store.repo.name))
        }
    }
}
