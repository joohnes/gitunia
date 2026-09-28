import Foundation
import AppKit
import UserNotifications
import GituniaCore

/// Turns `RepoEvent`s into macOS notifications. One per app (owned by `WorkspaceRegistry`), so the
/// per-repo coalescing also dedupes a repo that's open in two windows.
@MainActor
final class RepoNotifier {
    private let app: AppConfig
    private var coalescer = EventCoalescer()
    private var authorized: Bool?

    init(app: AppConfig) { self.app = app }

    func post(_ events: [RepoEvent], repo store: RepositoryStore) {
        guard app.settings.notificationsEnabled, !events.isEmpty,
              // `swift run`/tests have no bundle: UNUserNotificationCenter traps there.
              Bundle.main.bundleIdentifier != nil,
              coalescer.shouldDeliver(store.url.standardizedFileURL.path) else { return }
        let body = Self.lines(for: events, repo: store.repo.name, subject: store.repo.lastCommitSummary).joined(separator: "\n")
        let info = Self.userInfo(for: events, repoPath: store.url.standardizedFileURL.path)
        Task { await deliver(body, userInfo: info) }
    }

    /// What a click needs (`AppDelegate.handleNotificationTap`): the repo, plus the commit to jump to
    /// when the batch is exactly one new-commit / remote-push event.
    nonisolated static func userInfo(for events: [RepoEvent], repoPath: String) -> [String: String] {
        var info = ["repoPath": repoPath]
        if events.count == 1 {
            switch events[0] {
            case .headMoved(_, let to): info["hash"] = to
            case .remoteActivity(let a): info["hash"] = a.newOID
            default: break
            }
        }
        return info
    }

    nonisolated static func lines(for events: [RepoEvent], repo name: String, subject: String?) -> [String] {
        events.map { event in
            switch event {
            case .headMoved(_, let to):
                let short = String(to.prefix(7))
                return subject.map { "\(name): new commit \(short) — \($0)" } ?? "\(name): new commit \(short)"
            case .branchAdded(let branch): return "\(name): new branch \(branch)"
            case .operationStarted(let op): return op == .bisect ? "\(name): bisect started" : "\(name): \(op.label) stopped on conflicts"
            case .repositoryJoined: return "\(name): joined the workspace"
            case .remoteActivity(let a):
                let n = a.commits.count, commits = "\(n) new commit\(n == 1 ? "" : "s")"
                let by = Array(Set(a.commits.map(\.author))).sorted().joined(separator: ", ")
                let onRef = "\(commits) on \(a.ref)" + (by.isEmpty ? "" : " by \(by)")
                switch a.kind {
                case .branchCreated: return "\(name): new branch \(a.ref)" + (n > 0 ? " — \(onRef)" : "")
                case .branchUpdated, .baseAdvanced: return "\(name): \(onRef)"
                case .branchDeleted: return "\(name): branch \(a.ref) deleted"
                case .forcePushed: return "\(name): \(a.ref) was force-pushed"
                case .pullRequestMerged: return "\(name): merged #\(a.pullRequestNumber ?? 0)" + (a.pullRequestTitle.map { " \($0)" } ?? "")
                }
            }
        }
    }

    private func deliver(_ body: String, userInfo: [String: String]) async {
        let center = UNUserNotificationCenter.current()
        do {
            if authorized == nil { authorized = try await center.requestAuthorization(options: [.alert, .sound]) }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.body = body
            content.userInfo = userInfo
            content.threadIdentifier = userInfo["repoPath"] ?? ""   // Notification Center groups per repo
            content.categoryIdentifier = "repo"
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {}   // auth stays nil on failure, so the next event asks again
    }
}

extension WorkspaceRegistry {
    /// A notification click: focus the first window with the repo and select it, or jump to the
    /// commit in History when the notification carried one. When no open window has the repo,
    /// looks through recently opened `.gitunia-workspace` files for one that lists it (directly or
    /// under a linked folder) and opens that in a new window before retrying; if none lists it,
    /// toasts instead of just activating the app with nothing to show.
    func openFromNotification(repoPath: String, hash: String?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if select(repoPath: repoPath, hash: hash) { return }
        guard let workspace = Self.workspaceURL(containing: repoPath, recent: app.config.recentWorkspaces) else {
            toasts?.post(.error("\(URL(fileURLWithPath: repoPath).lastPathComponent) isn't open in any workspace"))
            return
        }
        Task {
            try? await open(workspace, from: nil)
            _ = select(repoPath: repoPath, hash: hash)
        }
    }

    /// Focuses/selects the repo if some open window already has it. Returns false otherwise.
    private func select(repoPath: String, hash: String?) -> Bool {
        guard let (id, ws, repo) = window(containing: repoPath) else { return false }
        if let hash, navigator.show(commit: hash, in: repo, preferWindow: id) { return true }
        ws.select(repo)
        openWindowAction?(id)
        return true
    }

    /// Pure lookup behind `openFromNotification`'s fallback: the first recent workspace file whose
    /// repositories list `repoPath`, or whose linked folders contain it.
    static func workspaceURL(containing repoPath: String, recent: [String]) -> URL? {
        let target = WorkspaceFile.standardize(repoPath)
        for path in recent {
            let fileURL = URL(fileURLWithPath: path)
            guard let file = try? WorkspaceFile.load(from: fileURL) else { continue }
            if file.repositories.contains(where: { WorkspaceFile.standardize($0) == target }) { return fileURL }
            if file.folders.contains(where: { target == WorkspaceFile.standardize($0.path) || target.hasPrefix(WorkspaceFile.standardize($0.path) + "/") }) {
                return fileURL
            }
        }
        return nil
    }
}
