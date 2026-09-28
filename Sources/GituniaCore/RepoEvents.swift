import Foundation

/// Something worth a system notification that happened to a repository between two
/// `RepositoryStore.refreshStatus()` results (or, for `.repositoryJoined`, a folder rescan).
public enum RepoEvent: Equatable, Sendable {
    case headMoved(from: String, to: String)
    case branchAdded(String)
    case operationStarted(GitOperation)
    case repositoryJoined
    /// A fetch/pull brought in remote activity (`RepositoryStore.recordRemoteActivity`).
    case remoteActivity(ActivityEvent)

    /// The slice of repository state the events are computed from.
    public struct Snapshot: Equatable, Sendable {
        public var headOID: String?
        public var branches: Set<String>
        public var operation: GitOperation?
        public init(headOID: String?, branches: Set<String>, operation: GitOperation?) {
            self.headOID = headOID; self.branches = branches; self.operation = operation
        }
    }

    public static func diff(old: Snapshot, new: Snapshot) -> [RepoEvent] {
        var events: [RepoEvent] = []
        if let from = old.headOID, let to = new.headOID, from != to { events.append(.headMoved(from: from, to: to)) }
        events += new.branches.subtracting(old.branches).sorted().map(RepoEvent.branchAdded)
        if old.operation == nil, let op = new.operation { events.append(.operationStarted(op)) }
        return events
    }
}

/// At most one delivery per key per `window`. Fixed window from the last delivery, dropped (not
/// queued) inside it.
/// ponytail: fixed 10s window drops events, queue a summary if users miss them.
public struct EventCoalescer {
    public var window: TimeInterval
    private let now: () -> Date
    private var last: [String: Date] = [:]

    public init(window: TimeInterval = 10, now: @escaping () -> Date = Date.init) {
        self.window = window; self.now = now
    }

    /// True (and records the time) when `key` may be delivered now.
    public mutating func shouldDeliver(_ key: String) -> Bool {
        let t = now()
        if let prev = last[key], t.timeIntervalSince(prev) < window { return false }
        last[key] = t
        return true
    }
}
