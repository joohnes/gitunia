import Foundation
import Observation

/// One repository's slice of `ActivityLog.digest(since:)`.
public struct ActivityDigestRepo: Equatable, Sendable {
    public let repoName: String
    public let repoPath: String
    public let events: [ActivityEvent]
    public let mergedPRs: Int
    public let newCommits: Int
    /// Most commits first.
    public let activeAuthors: [String]
    public let branchesCreated: Int
    public let branchesDeleted: Int
    /// `newCommits` split by `AgentProfile` — `agentCommits + humanCommits == newCommits`.
    public let agentCommits: Int
    public let humanCommits: Int
}

/// App-wide log of remote activity (`activity.json` next to `workspace.json`), shared by every
/// window. Newest first, capped at `maxEvents`.
@MainActor
@Observable
public final class ActivityLog {
    public private(set) var events: [ActivityEvent] = []
    public let fileURL: URL
    public static let maxEvents = 2000
    @ObservationIgnored private let saver = Debouncer()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) {
            events = decoded
        } else {
            FileBackup.preserveCorrupt(at: fileURL)
        }
    }

    public var unseenCount: Int { events.lazy.filter { !$0.seen }.count }

    /// Skips events already logged — two windows showing one repo each see the same fetch.
    public func append(_ new: [ActivityEvent]) {
        let fresh = new.filter { e in
            !events.contains { $0.repoPath == e.repoPath && $0.kind == e.kind && $0.ref == e.ref
                && $0.oldOID == e.oldOID && $0.newOID == e.newOID }
        }
        guard !fresh.isEmpty else { return }
        events = (fresh + events).sorted { $0.date > $1.date }
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        scheduleSave()
    }

    public func markSeen(repoPath: String? = nil) {
        var changed = false
        for i in events.indices where !events[i].seen && (repoPath == nil || events[i].repoPath == repoPath) {
            events[i].seen = true
            changed = true
        }
        if changed { scheduleSave() }
    }

    public func prune(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let before = events.count
        events.removeAll { $0.date < cutoff }
        if events.count != before { scheduleSave() }
    }

    /// Writes a pending debounced save now.
    public func flush() { saver.flush() }

    private func scheduleSave() {
        saver.schedule(.seconds(1)) { [weak self] in self?.save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(events).write(to: fileURL, options: .atomic)
    }

    // MARK: - Digest

    /// Events since `since`, grouped per repo, busiest (most new commits) first.
    public func digest(since: Date, agents: AgentProfile = AgentProfile()) -> [ActivityDigestRepo] {
        Dictionary(grouping: events.filter { $0.date >= since }, by: \.repoPath).map { path, events in
            // pullRequestMerged repeats a baseAdvanced commit — don't count it twice.
            let commits = events.filter { $0.kind != .pullRequestMerged && $0.kind != .branchDeleted }.flatMap(\.commits)
            let byAuthor = Dictionary(grouping: commits, by: \.author).mapValues(\.count)
            let agentCount = commits.filter { agents.matches(author: $0.author, email: $0.authorEmail) }.count
            return ActivityDigestRepo(
                repoName: events[0].repoName, repoPath: path, events: events,
                mergedPRs: events.filter { $0.kind == .pullRequestMerged }.count,
                newCommits: commits.count,
                activeAuthors: byAuthor.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key),
                branchesCreated: events.filter { $0.kind == .branchCreated }.count,
                branchesDeleted: events.filter { $0.kind == .branchDeleted }.count,
                agentCommits: agentCount, humanCommits: commits.count - agentCount)
        }
        .sorted { $0.newCommits != $1.newCommits ? $0.newCommits > $1.newCommits : $0.repoName < $1.repoName }
    }

    /// Standup-ready Markdown: one `##` section per repo.
    public nonisolated static func markdown(_ digest: [ActivityDigestRepo], since: Date) -> String {
        let when = since.formatted(date: .abbreviated, time: .shortened)
        var lines = ["# Activity since \(when)"]
        if digest.isEmpty { lines += ["", "No remote activity."] }
        for repo in digest {
            lines += ["", "## \(repo.repoName)"]
            let ordered = repo.events.sorted { $0.date < $1.date }
            for e in ordered {
                switch e.kind {
                case .pullRequestMerged:
                    lines.append("- Merged #\(e.pullRequestNumber ?? 0)" + (e.pullRequestTitle.map { " \($0)" } ?? ""))
                case .branchCreated, .branchUpdated, .baseAdvanced, .forcePushed:
                    let authors = Array(Set(e.commits.map(\.author))).sorted().joined(separator: ", ")
                    let n = e.commits.count
                    let commitText = n == 0 ? "" : "\(n) commit\(n == 1 ? "" : "s") on \(e.ref)" + (authors.isEmpty ? "" : " by \(authors)")
                    switch e.kind {
                    case .branchCreated: lines.append("- New branch \(e.ref)" + (commitText.isEmpty ? "" : " — \(commitText)"))
                    case .forcePushed: lines.append("- Force-pushed \(e.ref)" + (commitText.isEmpty ? "" : " — \(commitText)"))
                    default: if !commitText.isEmpty { lines.append("- \(commitText)") }
                    }
                case .branchDeleted:
                    lines.append("- Deleted branch \(e.ref)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
