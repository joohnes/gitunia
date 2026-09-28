import Foundation
import Observation

/// A single action button a toast can offer — e.g. "Force push…" on a rejected-push error toast.
/// `perform` is `@Sendable` so `Toast` itself can stay `Sendable`; every real call site is a
/// `@MainActor` type (`RemoteOpsCoordinator`, `RepositoryStore`) hopping back with `Task { @MainActor
/// in ... }` inside the closure, not something invoked off the main actor.
public struct ToastAction: Sendable {
    public let title: String
    public let perform: @Sendable () -> Void

    public init(title: String, perform: @escaping @Sendable () -> Void) {
        self.title = title
        self.perform = perform
    }
}

public struct Toast: Identifiable, Sendable {
    public enum Style: Sendable, Equatable { case success, info, error }

    public let id: UUID
    public let style: Style
    public let title: String
    public let detail: String?
    public let stderr: String?
    /// The git command that failed (already credential-redacted by `GitError`), shown in the
    /// error toast's details popover.
    public let command: String?
    public let action: ToastAction?

    public init(id: UUID = UUID(), style: Style, title: String, detail: String? = nil, stderr: String? = nil,
                command: String? = nil, action: ToastAction? = nil) {
        self.id = id; self.style = style; self.title = title; self.detail = detail; self.stderr = stderr
        self.command = command; self.action = action
    }

    public static func success(_ title: String, detail: String? = nil) -> Toast {
        Toast(style: .success, title: title, detail: detail)
    }

    public static func info(_ title: String, detail: String? = nil) -> Toast {
        Toast(style: .info, title: title, detail: detail)
    }

    public static func error(_ title: String, detail: String? = nil, stderr: String? = nil, command: String? = nil,
                             action: ToastAction? = nil) -> Toast {
        Toast(style: .error, title: title, detail: detail, stderr: stderr, command: command, action: action)
    }

    /// Turns a remote-operation result into the right toast: error with stderr on failure,
    /// success with the parsed summary otherwise.
    public init(remote: RemoteResult, repo: String) {
        if remote.succeeded {
            self = .success(repo, detail: remote.summary)
        } else {
            self = .error(repo, detail: remote.summary, stderr: remote.error?.stderr,
                          command: remote.error?.commandLine)
        }
    }
}

@MainActor
@Observable
public final class ToastCenter {
    public private(set) var toasts: [Toast] = []
    private var expiryTasks: [Toast.ID: Task<Void, Never>] = [:]
    private let autoDismiss: Duration
    /// Toasts with an action (e.g. Undo) stay longer so there's time to reach the button.
    private let actionAutoDismiss: Duration
    private let maxQueued: Int

    public init(autoDismiss: Duration = .seconds(4), actionAutoDismiss: Duration = .seconds(8), maxQueued: Int = 5) {
        self.autoDismiss = autoDismiss
        self.actionAutoDismiss = actionAutoDismiss
        self.maxQueued = maxQueued
    }

    public func post(_ toast: Toast) {
        toasts.append(toast)
        if toasts.count > maxQueued {
            let overflow = toasts.count - maxQueued
            for t in toasts[..<overflow] { cancelExpiry(t.id) }
            toasts.removeFirst(overflow)
        }
        guard toast.style != .error else { return }
        let id = toast.id
        let delay = toast.action == nil ? autoDismiss : actionAutoDismiss
        expiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    public func dismiss(_ id: Toast.ID) {
        toasts.removeAll { $0.id == id }
        cancelExpiry(id)
    }

    private func cancelExpiry(_ id: Toast.ID) {
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
    }
}
