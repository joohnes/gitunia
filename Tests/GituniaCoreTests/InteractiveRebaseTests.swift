import XCTest
@testable import GituniaCore

/// Tidy Commits: the pure todo rendering/validation, then real `git rebase -i` runs in temp repos.
final class InteractiveRebaseTests: XCTestCase {
    private let git = GitRunner()
    typealias Line = RebaseTodo.Line

    // MARK: - Pure

    func testRenderKeepsOrderAndTurnsMessagesIntoExec() {
        let lines = [Line(hash: "a1", subject: "one"),
                     Line(action: .reword, hash: "b2", subject: "two", newMessage: "Two"),
                     Line(action: .squash, hash: "c3", subject: "three", newMessage: "Both"),
                     Line(action: .fixup, hash: "d4", subject: "four"),
                     Line(action: .drop, hash: "e5", subject: "five"),
                     Line(action: .squash, hash: "f6", subject: "six")]
        let todo = RebaseTodo.render(lines, messageFiles: [1: "/t/msg-1", 2: "/t/it's"])
        XCTAssertEqual(todo, """
            pick a1 one
            pick b2 two
            exec git commit --amend --allow-empty --no-verify -q -F '/t/msg-1'
            fixup c3 three
            exec git commit --amend --allow-empty --no-verify -q -F '/t/it'\\''s'
            fixup d4 four
            drop e5 five
            squash f6 six

            """)
        XCTAssertFalse(todo.contains("Both"), "messages never go into the todo")
    }

    func testValidate() {
        XCTAssertNil(RebaseTodo.validate([Line(hash: "a", subject: "a"), Line(action: .squash, hash: "b", subject: "b")]))
        XCTAssertNotNil(RebaseTodo.validate([Line(action: .squash, hash: "a", subject: "a")]))
        XCTAssertNotNil(RebaseTodo.validate([Line(action: .drop, hash: "a", subject: "a"), Line(action: .fixup, hash: "b", subject: "b")]))
        XCTAssertNotNil(RebaseTodo.validate([Line(action: .drop, hash: "a", subject: "a")]))
        XCTAssertNotNil(RebaseTodo.validate([]))
        XCTAssertEqual(RebaseTodo.summary([Line(hash: "a", subject: ""), Line(action: .squash, hash: "b", subject: ""),
                                           Line(action: .drop, hash: "c", subject: "")]), "3 commits → 1, 1 dropped")
    }

    /// B11: the ▲/▼ fallback buttons and `.onMove` both go through this.
    func testMoveLine() {
        let lines = [Line(hash: "a", subject: ""), Line(hash: "b", subject: ""), Line(hash: "c", subject: "")]
        XCTAssertEqual(RebaseTodo.moveLine(lines, from: 0, to: 1).map(\.hash), ["b", "a", "c"])
        XCTAssertEqual(RebaseTodo.moveLine(lines, from: 2, to: 0).map(\.hash), ["c", "a", "b"])
        // Out-of-range `to` clamps instead of crashing or dropping the line.
        XCTAssertEqual(RebaseTodo.moveLine(lines, from: 0, to: 99).map(\.hash), ["b", "c", "a"])
        // Out-of-range `from` is a no-op.
        XCTAssertEqual(RebaseTodo.moveLine(lines, from: 99, to: 0).map(\.hash), ["a", "b", "c"])
    }

    // MARK: - Integration

    /// init + c1…c4 (each its own file). Returns the store and the 4 commits oldest first.
    @MainActor private func makeRepo() async throws -> (RepositoryStore, [CommitInfo]) {
        let url = try await TestHelpers.makeTempRepo()
        for n in 1...4 {
            try TestHelpers.write("\(n)\n", to: url, "f\(n).txt")
            _ = try await git.run(["add", "."], in: url)
            _ = try await git.run(["commit", "-q", "-m", "c\(n)"], in: url)
        }
        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let commits = await store.rewritableCommits(limit: 4)
        XCTAssertEqual(commits.map(\.subject), ["c4", "c3", "c2", "c1"])
        return (store, commits.reversed())
    }

    private func lines(_ commits: [CommitInfo]) -> [Line] {
        commits.map { Line(hash: $0.hash, subject: $0.subject) }
    }

    @MainActor private func subjects(_ store: RepositoryStore) async -> [String] {
        await store.history().map(\.subject)
    }

    /// `merge-base --is-ancestor` failing outright (exit 128) is "unknown", not "not pushed".
    @MainActor func testRefusesWhenPushedCheckCannotRun() async throws {
        let (store, commits) = try await makeRepo()
        store.hasUpstream = true // stale: no @{upstream} actually resolves
        let error = await store.interactiveRebase(lines(commits))
        XCTAssertNotNil(error)
        let after = await subjects(store)
        XCTAssertEqual(after, ["c4", "c3", "c2", "c1", "init"])
    }

    @MainActor func testDrop() async throws {
        let (store, commits) = try await makeRepo()
        var todo = lines(commits)
        todo[1].action = .drop
        do { let e = await store.interactiveRebase(todo); XCTAssertNil(e) }
        do { let v = await subjects(store); XCTAssertEqual(v, ["c4", "c3", "c1", "init"]) }
        XCTAssertNil(store.operation)
    }

    @MainActor func testSquashWithMessage() async throws {
        let (store, commits) = try await makeRepo()
        var todo = lines(commits)
        todo[2].action = .squash
        todo[2].newMessage = "c2 and c3\n\nbody line"
        do { let e = await store.interactiveRebase(todo); XCTAssertNil(e) }
        do { let v = await subjects(store); XCTAssertEqual(v, ["c4", "c2 and c3", "c1", "init"]) }
        let body = try await git.run(["log", "-1", "--format=%B", "HEAD~1"], in: store.url)
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), "c2 and c3\n\nbody line")
        let files = try await git.run(["show", "--name-only", "--format=", "HEAD~1"], in: store.url)
        XCTAssertEqual(files.split(separator: "\n"), ["f2.txt", "f3.txt"])
    }

    @MainActor func testSquashWithoutMessageKeepsCombined() async throws {
        let (store, commits) = try await makeRepo()
        var todo = lines(commits)
        todo[3].action = .squash
        do { let e = await store.interactiveRebase(todo); XCTAssertNil(e) }
        let body = try await git.run(["log", "-1", "--format=%B"], in: store.url)
        XCTAssertTrue(body.contains("c3") && body.contains("c4"), body)
        XCTAssertFalse(body.contains("#"), "comment lines are stripped")
        do { let v = await store.history().count; XCTAssertEqual(v, 4) }
    }

    @MainActor func testRewordOldest() async throws {
        let (store, commits) = try await makeRepo()
        var todo = lines(commits)
        todo[0].action = .reword
        todo[0].newMessage = "first, reworded"
        do { let e = await store.interactiveRebase(todo); XCTAssertNil(e) }
        do { let v = await subjects(store); XCTAssertEqual(v, ["c4", "c3", "c2", "first, reworded", "init"]) }
    }

    @MainActor func testReorder() async throws {
        let (store, commits) = try await makeRepo()
        let todo = lines([commits[3], commits[0], commits[2], commits[1]])
        do { let e = await store.interactiveRebase(todo); XCTAssertNil(e) }
        do { let v = await subjects(store); XCTAssertEqual(v, ["c2", "c3", "c1", "c4", "init"]) }
    }

    @MainActor func testRootCommitIncluded() async throws {
        let (store, _) = try await makeRepo()
        let all = await store.history().reversed()
        var todo = lines(Array(all))
        todo[1].action = .fixup
        do { let e = await store.interactiveRebase(todo); XCTAssertNil(e) }
        do { let v = await subjects(store); XCTAssertEqual(v, ["c4", "c3", "c2", "init"]) }
    }

    @MainActor func testDirtyTreeRefused() async throws {
        let (store, commits) = try await makeRepo()
        try TestHelpers.write("changed\n", to: store.url, "f1.txt")
        await store.refreshStatus()
        XCTAssertNotNil(store.interactiveRebaseBlocker)
        var todo = lines(commits)
        todo[1].action = .drop
        let error = await store.interactiveRebase(todo)
        XCTAssertTrue(error?.stderr.contains("stash or commit first") == true)
        do { let v = await store.history().count; XCTAssertEqual(v, 5) }
    }

    @MainActor func testPartialTipRefused() async throws {
        let (store, commits) = try await makeRepo()
        let error = await store.interactiveRebase(lines(Array(commits.prefix(2))))
        XCTAssertNotNil(error, "leaving out newer commits would lose them")
        do { let v = await store.history().count; XCTAssertEqual(v, 5) }
    }

    @MainActor func testPushedCommitRefused() async throws {
        let (store, commits) = try await makeRepo()
        let bare = try TestHelpers.makeTempDir()
        _ = try await git.run(["init", "-q", "-b", "master", "--bare", bare.path], in: store.url)
        _ = try await git.run(["remote", "add", "origin", bare.path], in: store.url)
        _ = try await git.run(["push", "-q", "-u", "origin", "HEAD~2:refs/heads/master"], in: store.url)
        _ = try await git.run(["branch", "-q", "--set-upstream-to=origin/master"], in: store.url)
        await store.refreshStatus()

        do { let v = await store.rewritableCommits().map(\.subject); XCTAssertEqual(v, ["c4", "c3"]) }
        var todo = lines(commits)
        todo[3].action = .drop
        let error = await store.interactiveRebase(todo)
        XCTAssertTrue(error?.stderr.contains("already pushed") == true, "\(String(describing: error))")
        do { let v = await store.history().count; XCTAssertEqual(v, 5) }

        var unpushed = lines(Array(commits.suffix(2)))
        unpushed[1].action = .fixup
        do { let e = await store.interactiveRebase(unpushed); XCTAssertNil(e) }
        do { let v = await subjects(store); XCTAssertEqual(v, ["c3", "c2", "c1", "init"]) }
    }
}
