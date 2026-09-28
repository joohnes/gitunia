import XCTest
@testable import GituniaCore

final class PreflightTests: XCTestCase {
    private func repo(ahead: Int = 0, behind: Int = 0, changes: [FileChange] = [], isAvailable: Bool = true,
                       lastCommitSummary: String? = "init") -> Repository {
        var r = Repository(id: URL(fileURLWithPath: "/tmp/repo"), name: "repo", branch: "main",
                           ahead: ahead, behind: behind, changes: changes)
        r.lastCommitSummary = lastCommitSummary
        r.isAvailable = isAvailable
        return r
    }

    private func change(_ path: String, status: FileChange.Status, area: FileChange.Area) -> FileChange {
        FileChange(path: path, status: status, area: area)
    }

    func testCleanRepoNoIssues() {
        XCTAssertEqual(Preflight.check(.checkout(branch: "main"), repo: repo(), hasUpstream: true), [])
        XCTAssertEqual(Preflight.check(.pull, repo: repo(behind: 1), hasUpstream: true), [])
        XCTAssertEqual(Preflight.check(.push, repo: repo(ahead: 1), hasUpstream: true), [])
        XCTAssertEqual(Preflight.check(.commit, repo: repo(changes: [change("a", status: .modified, area: .staged)]), hasUpstream: true), [])
    }

    func testCheckoutWithUncommittedChangesBlocks() {
        // Staged changes are still carried across a checkout, so they block too.
        let cases: [(String, FileChange.Status, FileChange.Area)] = [
            ("unstaged", .modified, .unstaged),
            ("untracked", .untracked, .unstaged),
            ("staged", .modified, .staged),
        ]
        for (name, status, area) in cases {
            let r = repo(changes: [change("a.txt", status: status, area: area)])
            let issues = Preflight.check(.checkout(branch: "develop"), repo: r, hasUpstream: true)
            XCTAssertEqual(issues.map(\.id), ["uncommitted"], name)
            XCTAssertEqual(issues.map(\.severity), [.blocker], name)
        }
    }

    func testCheckoutOrPullWithConflictBlocks() {
        let r = repo(changes: [
            change("a.txt", status: .conflicted, area: .unstaged),
            change("b.txt", status: .conflicted, area: .unstaged)
        ])
        let checkoutIssues = Preflight.check(.checkout(branch: "main"), repo: r, hasUpstream: true)
        XCTAssertTrue(checkoutIssues.contains { $0.id == "conflicted" && $0.severity == .blocker })

        let pullIssues = Preflight.check(.pull, repo: r, hasUpstream: true)
        XCTAssertTrue(pullIssues.contains { $0.id == "conflicted" && $0.severity == .blocker })
    }

    func testAmendWithNoCommitsBlocks() {
        let r = repo(lastCommitSummary: nil)
        let issues = Preflight.check(.amend, repo: r, hasUpstream: false)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].id, "no-commits")
    }

    func testAmendOfPushedCommitWarns() {
        // hasUpstream && ahead == 0 means HEAD matches the remote-tracking ref.
        let r = repo(ahead: 0)
        let issues = Preflight.check(.amend, repo: r, hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertEqual(issues[0].id, "amend-pushed")
    }

    func testAmendWithNothingStagedIsNotBlocked() {
        // Amending to just reword a message, with nothing (re-)staged, is legitimate — unlike
        // a plain commit, .amend must not carry the "nothing staged" blocker.
        let r = repo(ahead: 1, changes: [])
        XCTAssertEqual(Preflight.check(.amend, repo: r, hasUpstream: true), [])
    }

    func testUnavailableRepoBlocksEveryAction() {
        let r = repo(isAvailable: false)
        for action: PreflightAction in [.checkout(branch: "main"), .pull, .push, .forcePush, .commit, .amend, .undoLastCommit(hasParent: true)] {
            let issues = Preflight.check(action, repo: r, hasUpstream: true)
            XCTAssertEqual(issues.count, 1)
            XCTAssertEqual(issues[0].severity, .blocker)
            XCTAssertEqual(issues[0].id, "unavailable")
        }
    }

    // MARK: - undoLastCommit

    func testUndoLastCommitWithNoParentBlocks() {
        let issues = Preflight.check(.undoLastCommit(hasParent: false), repo: repo(), hasUpstream: false)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].id, "no-parent")
    }

    func testUndoOfPushedCommitBlocksUnlikeAmendsWarning() {
        // Same "ahead == 0 with an upstream" condition amend only warns on — undo blocks instead
        // (see the reasoning comment in Preflight.swift): it deletes the commit outright rather
        // than leaving a reworded one in place, so it gets the toolbar's override treatment.
        let r = repo(ahead: 0)
        let issues = Preflight.check(.undoLastCommit(hasParent: true), repo: r, hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].id, "undo-pushed")
    }

    func testUndoOfLocalOnlyCommitHasNoIssues() {
        let r = repo(ahead: 1)
        XCTAssertEqual(Preflight.check(.undoLastCommit(hasParent: true), repo: r, hasUpstream: true), [])
    }

    // MARK: - forcePush

    func testForcePushWithoutUpstreamBlocks() {
        let issues = Preflight.check(.forcePush, repo: repo(), hasUpstream: false)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].id, "no-upstream")
    }

    func testForcePushWhenBehindWarns() {
        let issues = Preflight.check(.forcePush, repo: repo(behind: 3), hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertEqual(issues[0].id, "behind")
    }

    // MARK: - reset

    func testResetBlockedDuringOperation() {
        let issues = Preflight.checkReset(repo: repo(), operation: .rebase, impact: ResetImpact(undone: 1, pushed: 0))
        XCTAssertEqual(issues.map(\.id), ["operation-in-progress"])
        XCTAssertEqual(issues.first?.severity, .blocker)
    }

    // MARK: - large files

    func testLargeFileWarningsOnlyForStagedFilesOverThreshold() {
        let changes = [
            FileChange(path: "big.bin", status: .added, area: .staged, size: 12_000_000),
            FileChange(path: "small.txt", status: .modified, area: .staged, size: 4_000_000),
            FileChange(path: "unstaged.bin", status: .modified, area: .unstaged, size: 50_000_000),
            FileChange(path: "unknown.bin", status: .added, area: .staged),
        ]
        let issues = Preflight.largeFileWarnings(in: changes)
        XCTAssertEqual(issues.map(\.id), ["large-file:big.bin"])
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertEqual(Preflight.check(.commit, repo: repo(changes: changes), hasUpstream: true).map(\.id), ["large-file:big.bin"])
    }

    func testLargeFileWarningsSkipLFSTrackedAndSuggestTrackPattern() {
        let changes = [
            FileChange(path: "art/cover.psd", status: .added, area: .staged, size: 90_000_000),
            FileChange(path: "big.bin", status: .added, area: .staged, size: 12_000_000),
        ]
        let rules = GitAttributes.parse("*.psd filter=lfs diff=lfs merge=lfs -text")
        let issues = Preflight.largeFileWarnings(in: changes, rules: rules)
        XCTAssertEqual(issues.map(\.id), ["large-file:big.bin"])
        XCTAssertEqual(issues.first?.suggestedLFSPattern, "*.bin")
        XCTAssertEqual(issues.first?.suggestedLFSPattern, "*.bin")
        XCTAssertNil(Preflight.largeFileWarnings(in: changes).last?.suggestedLFSPattern)
        XCTAssertEqual(Preflight.largeFileWarnings(in: changes, lfsInstalled: true).last?.suggestedLFSPattern, "*.bin")
    }
}
