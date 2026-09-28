import XCTest
@testable import GituniaCore

/// C16 moved `recordRemoteActivity` off of `fetch()`'s awaited path into a detached `Task`, so a
/// fetch that just returned doesn't guarantee the activity diff has run yet — hence `TestHelpers.waitUntil`.
final class RemoteActivityTests: XCTestCase {
    // MARK: - Pure

    func testParseRefsSkipsHEAD() {
        let out = "origin 111\norigin/HEAD 111\norigin/master 111\norigin/feat/x 222\nupstream/dev 333\n"
        XCTAssertEqual(RemoteActivity.parseRefs(out), ["origin/master": "111", "origin/feat/x": "222", "upstream/dev": "333"])
    }

    func testDiffAllFourKinds() {
        let old = RemoteRefSnapshot(refs: ["origin/master": "a", "origin/feat": "b", "origin/gone": "c", "origin/same": "d"])
        let new = RemoteRefSnapshot(refs: ["origin/master": "a2", "origin/feat": "b2", "origin/new": "e", "origin/same": "d"])
        let diff = RemoteActivity.diff(old: old, new: new, baseRef: "origin/master")
        XCTAssertEqual(diff.map(\.ref), ["origin/feat", "origin/gone", "origin/master", "origin/new"])
        XCTAssertEqual(diff.map(\.kind), [.branchUpdated, .branchDeleted, .baseAdvanced, .branchCreated])
        XCTAssertEqual(diff.map(\.oldOID), ["b", "c", "a", nil])
        XCTAssertEqual(diff.map(\.newOID), ["b2", nil, "a2", "e"])
    }

    func testPullRequestNumber() {
        XCTAssertEqual(RemoteActivity.pullRequestNumber(inSubject: "Merge pull request #123 from x/y"), 123)
        XCTAssertEqual(RemoteActivity.pullRequestNumber(inSubject: "feat: add x (#45)"), 45)
        XCTAssertNil(RemoteActivity.pullRequestNumber(inSubject: "fix: issue #9 in parser"))
        XCTAssertNil(RemoteActivity.pullRequestNumber(inSubject: "chore: bump (deps)"))
    }

    func testParseCommits() {
        let out = "abc\u{1f}feat: x (#7)\u{1f}agent-1\u{1f}a@x.io\u{1f}2026-09-24T10:00:00+02:00\nbroken line\n"
        let commits = RemoteActivity.parseCommits(out)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].hash, "abc")
        XCTAssertEqual(commits[0].subject, "feat: x (#7)")
        XCTAssertEqual(commits[0].author, "agent-1")
        XCTAssertEqual(commits[0].authorEmail, "a@x.io")
        XCTAssertEqual(commits[0].date, ISO8601DateFormatter().date(from: "2026-09-24T08:00:00Z"))
    }

    // MARK: - Integration (local bare remote, fake gh)

    private static let ghScript = """
    #!/bin/sh
    echo '[{"number":7,"title":"Add x","mergedAt":"2026-09-24T10:00:00Z"}]'
    """

    @MainActor
    func testFetchRecordsRemoteActivity() async throws {
        let git = GitRunner()
        print("git version:", (try? await git.run(["--version"], in: FileManager.default.temporaryDirectory)) ?? "?")
        let a = try await TestHelpers.makeTempRepo()
        _ = try await git.run(["config", "user.name", "agent-1"], in: a)
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", "-b", "master", remote.path], in: a)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: a)
        _ = try await git.run(["push", "-q", "-u", "origin", "master"], in: a)
        let b = try TestHelpers.makeTempDir().appendingPathComponent("b")
        _ = try await git.run(["clone", "-q", remote.path, b.path], in: a)

        let store = RepositoryStore(url: b)
        await store.refreshStatus()
        let bin = try TestHelpers.makeTempDir()
        let ghPath = bin.appendingPathComponent("gh").path
        try Self.ghScript.write(toFile: ghPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghPath)
        store.gh = GHRunner(executable: ghPath)
        store.hasGitHubRemote = true
        store.tracksRemoteActivity = true
        var received: [ActivityEvent] = []
        store.onRemoteActivity = { received += $0 }

        _ = await store.fetch()                       // baseline only
        try await TestHelpers.waitUntil { store.remoteSnapshot != nil }
        XCTAssertNotNil(store.remoteSnapshot)
        XCTAssertTrue(received.isEmpty)

        func commit(_ subject: String, _ file: String) async throws {
            try TestHelpers.write(subject + "\n", to: a, file)
            _ = try await git.run(["add", "."], in: a)
            _ = try await git.run(["commit", "-q", "-m", subject], in: a)
        }
        _ = try await git.run(["checkout", "-q", "-b", "feat-x"], in: a)
        try await commit("wip: feat x", "f.txt")
        _ = try await git.run(["push", "-q", "origin", "feat-x"], in: a)
        _ = try await git.run(["checkout", "-q", "master"], in: a)
        try await commit("feat: x (#7)", "x.txt")
        try await commit("Merge pull request #8 from a/b", "y.txt")
        _ = try await git.run(["push", "-q", "origin", "master"], in: a)

        let fetched = await store.fetch()
        XCTAssertTrue(fetched.succeeded)
        try await TestHelpers.waitUntil { received.contains { $0.kind == .branchCreated } }
        let created = try XCTUnwrap(received.first { $0.kind == .branchCreated })
        XCTAssertEqual(created.ref, "origin/feat-x")
        XCTAssertEqual(created.commits.map(\.subject), ["wip: feat x"])
        let advanced = try XCTUnwrap(received.first { $0.kind == .baseAdvanced })
        XCTAssertEqual(advanced.ref, "origin/master")
        XCTAssertEqual(advanced.commits.map(\.subject), ["Merge pull request #8 from a/b", "feat: x (#7)"])
        XCTAssertEqual(advanced.commits.first?.author, "agent-1")
        let merged = received.filter { $0.kind == .pullRequestMerged }
        XCTAssertEqual(merged.compactMap(\.pullRequestNumber).sorted(), [7, 8])
        XCTAssertEqual(merged.first { $0.pullRequestNumber == 7 }?.pullRequestTitle, "Add x")   // from gh
        XCTAssertEqual(merged.first { $0.pullRequestNumber == 7 }?.commits.count, 1)

        let ages = await store.remoteBranchAges()
        XCTAssertEqual(Set(ages.map(\.ref)), ["origin/master", "origin/feat-x"])
        XCTAssertEqual(ages.first { $0.ref == "origin/feat-x" }?.mergedIntoBase, false)
        XCTAssertEqual(ages.first { $0.ref == "origin/master" }?.mergedIntoBase, true)
        XCTAssertEqual(ages.first { $0.ref == "origin/feat-x" }?.author, "agent-1")

        received = []
        _ = try await git.run(["checkout", "-q", "feat-x"], in: a)
        _ = try await git.run(["commit", "-q", "--amend", "-m", "rewritten"], in: a)
        _ = try await git.run(["push", "-q", "--force", "origin", "feat-x"], in: a)
        _ = await store.fetch()
        try await TestHelpers.waitUntil { !received.isEmpty }
        XCTAssertEqual(received.map(\.kind), [.forcePushed])
        XCTAssertEqual(received.first?.commits.map(\.subject), ["rewritten"])

        received = []
        _ = try await git.run(["push", "-q", "origin", "--delete", "feat-x"], in: a)
        _ = await store.fetch()
        try await TestHelpers.waitUntil { !received.isEmpty }
        XCTAssertEqual(received.map(\.kind), [.branchDeleted])

        received = []
        _ = await store.fetch()
        try await Task.sleep(for: .milliseconds(150)) // nothing changed: no event will ever arrive to poll for
        XCTAssertTrue(received.isEmpty)
    }

    /// C16: `recordRemoteActivity`/`gh pr list` must not extend `isBusy` past the fetch itself —
    /// `performRemote` hands them off to a detached `Task` right after the fetch returns. Checked
    /// against real timing (`isBusy` already false the instant `fetch()` returns) while the activity
    /// event still arrives shortly after, via an expectation rather than a race-prone `Task.sleep`.
    @MainActor
    func testFetchClearsIsBusyBeforeActivityEventArrives() async throws {
        let git = GitRunner()
        let a = try await TestHelpers.makeTempRepo()
        let remote = try TestHelpers.makeTempDir().appendingPathComponent("remote.git")
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", "-b", "master", remote.path], in: a)
        _ = try await git.run(["remote", "add", "origin", remote.path], in: a)
        _ = try await git.run(["push", "-q", "-u", "origin", "master"], in: a)
        let b = try TestHelpers.makeTempDir().appendingPathComponent("b")
        _ = try await git.run(["clone", "-q", remote.path, b.path], in: a)

        let store = RepositoryStore(url: b)
        await store.refreshStatus()
        store.tracksRemoteActivity = true
        _ = await store.fetch() // baseline snapshot only

        try TestHelpers.write("x\n", to: a, "x.txt")
        _ = try await git.run(["add", "."], in: a)
        _ = try await git.run(["commit", "-q", "-m", "feat: x"], in: a)
        _ = try await git.run(["push", "-q"], in: a)

        let expectation = expectation(description: "activity event arrives")
        store.onRemoteActivity = { events in if !events.isEmpty { expectation.fulfill() } }

        let fetched = await store.fetch()
        XCTAssertTrue(fetched.succeeded)
        XCTAssertFalse(store.isBusy, "isBusy must already be clear right after fetch() returns")

        await fulfillment(of: [expectation], timeout: 5)
    }
}

@MainActor
final class ActivityLogTests: XCTestCase {
    private func event(_ kind: ActivityEventKind, repo: String = "/r/app", ref: String = "origin/master", new: String? = "n",
                       commits: [ActivityCommit] = [], pr: Int? = nil, title: String? = nil, date: Date = Date()) -> ActivityEvent {
        ActivityEvent(repoPath: repo, repoName: URL(fileURLWithPath: repo).lastPathComponent, kind: kind, ref: ref,
                      oldOID: "o", newOID: new, commits: commits, pullRequestNumber: pr, pullRequestTitle: title, date: date)
    }

    private func commit(_ author: String, _ n: Int) -> ActivityCommit {
        ActivityCommit(hash: "\(author)\(n)", subject: "s\(n)", author: author, authorEmail: "\(author)@x", date: Date())
    }

    private func tempURL() throws -> URL { try TestHelpers.makeTempDir().appendingPathComponent("activity.json") }

    func testAppendMarkSeenUnseenPrune() throws {
        let log = ActivityLog(fileURL: try tempURL())
        let old = event(.branchCreated, ref: "origin/old", date: Date().addingTimeInterval(-20 * 86_400))
        let a = event(.branchUpdated, ref: "origin/a", date: Date().addingTimeInterval(-60))
        let b = event(.branchCreated, repo: "/r/other", ref: "origin/b")
        log.append([a, old])
        log.append([b])
        XCTAssertEqual(log.events.map(\.ref), ["origin/b", "origin/a", "origin/old"])   // newest first
        log.append([event(.branchUpdated, ref: "origin/a")])                          // same change again: deduped
        XCTAssertEqual(log.events.count, 3)
        XCTAssertEqual(log.unseenCount, 3)
        log.markSeen(repoPath: "/r/other")
        XCTAssertEqual(log.unseenCount, 2)
        log.markSeen()
        XCTAssertEqual(log.unseenCount, 0)
        log.prune(olderThan: 14)
        XCTAssertEqual(log.events.map(\.ref), ["origin/b", "origin/a"])
    }

    func testPersistRoundTrip() throws {
        let url = try tempURL()
        let log = ActivityLog(fileURL: url)
        log.append([event(.pullRequestMerged, commits: [commit("agent-1", 1)], pr: 7, title: "Add x")])
        log.markSeen()
        log.flush()
        let reloaded = ActivityLog(fileURL: url)
        XCTAssertEqual(reloaded.events, log.events)
        XCTAssertEqual(reloaded.events.first?.seen, true)
    }

    func testCorruptFileStartsEmptyAndKeepsCopy() throws {
        let url = try tempURL()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let log = ActivityLog(fileURL: url)
        XCTAssertTrue(log.events.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("activity.json.corrupt-") })
    }

    func testDigestAndMarkdown() throws {
        let log = ActivityLog(fileURL: try tempURL())
        let since = Date().addingTimeInterval(-3600)
        let c1 = commit("agent-1", 1), c2 = commit("agent-1", 2), c3 = commit("agent-2", 3)
        log.append([
            event(.baseAdvanced, commits: [c1, c3]),
            event(.pullRequestMerged, new: c1.hash, commits: [c1], pr: 123, title: "Add login"),
            event(.branchCreated, ref: "origin/feat-x", new: "f", commits: [c2]),
            event(.branchDeleted, ref: "origin/stale", new: nil),
            event(.branchUpdated, repo: "/r/quiet", ref: "origin/dev", new: "q", commits: [commit("bob", 9)]),
            event(.branchCreated, repo: "/r/ancient", ref: "origin/x", date: Date().addingTimeInterval(-7200)),
        ])
        let digest = log.digest(since: since)
        XCTAssertEqual(digest.map(\.repoName), ["app", "quiet"])
        let app = digest[0]
        XCTAssertEqual(app.newCommits, 3)
        XCTAssertEqual(app.mergedPRs, 1)
        XCTAssertEqual(app.activeAuthors, ["agent-1", "agent-2"])
        XCTAssertEqual(app.branchesCreated, 1)
        XCTAssertEqual(app.branchesDeleted, 1)

        let md = ActivityLog.markdown(digest, since: since)
        XCTAssertTrue(md.hasPrefix("# Activity since "))
        XCTAssertTrue(md.contains("## app\n"))
        XCTAssertTrue(md.contains("## quiet\n"))
        XCTAssertTrue(md.contains("- Merged #123 Add login"))
        XCTAssertTrue(md.contains("- 2 commits on origin/master by agent-1, agent-2"))
        XCTAssertTrue(md.contains("- New branch origin/feat-x — 1 commit on origin/feat-x by agent-1"))
        XCTAssertTrue(md.contains("- Deleted branch origin/stale"))
        XCTAssertFalse(md.contains("ancient"))
        XCTAssertTrue(ActivityLog.markdown([], since: since).contains("No remote activity."))
    }

    func testDigestSplitsAgentAndHumanCommits() throws {
        let log = ActivityLog(fileURL: try tempURL())
        log.append([event(.baseAdvanced, commits: [commit("robo", 1), commit("robo", 2), commit("alice", 3)])])
        let app = try XCTUnwrap(log.digest(since: .distantPast, agents: AgentProfile(patterns: ["robo@"])).first)
        XCTAssertEqual(app.agentCommits, 2)
        XCTAssertEqual(app.humanCommits, 1)
        // Defaults don't know "robo".
        XCTAssertEqual(log.digest(since: .distantPast).first?.agentCommits, 0)
    }

    func testAppConfigOwnsLogNextToWorkspaceJSON() throws {
        let cfg = try TestHelpers.makeTempDir().appendingPathComponent("workspace.json")
        let app = AppConfig(configStore: ConfigStore(fileURL: cfg))
        XCTAssertEqual(app.activity.fileURL, cfg.deletingLastPathComponent().appendingPathComponent("activity.json"))
    }
}
