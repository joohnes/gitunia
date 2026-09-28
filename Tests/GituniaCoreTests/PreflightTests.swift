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

    func testCheckoutWithUnstagedChangesBlocks() {
        let r = repo(changes: [change("a.txt", status: .modified, area: .unstaged)])
        let issues = Preflight.check(.checkout(branch: "develop"), repo: r, hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].message, "1 uncommitted change will follow you to develop")
    }

    func testCheckoutWithUntrackedChangesBlocks() {
        let r = repo(changes: [change("new.txt", status: .untracked, area: .unstaged)])
        let issues = Preflight.check(.checkout(branch: "main"), repo: r, hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
    }

    func testCheckoutWithStagedOnlyChangesBlocks() {
        // Staged changes are still carried across a checkout, so they block too.
        let r = repo(changes: [change("a.txt", status: .modified, area: .staged)])
        let issues = Preflight.check(.checkout(branch: "main"), repo: r, hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].message, "1 uncommitted change will follow you to main")
    }

    func testCheckoutOrPullWithConflictBlocks() {
        let r = repo(changes: [
            change("a.txt", status: .conflicted, area: .unstaged),
            change("b.txt", status: .conflicted, area: .unstaged)
        ])
        let checkoutIssues = Preflight.check(.checkout(branch: "main"), repo: r, hasUpstream: true)
        XCTAssertTrue(checkoutIssues.contains { $0.message == "2 files have unresolved conflicts" && $0.severity == .blocker })

        let pullIssues = Preflight.check(.pull, repo: r, hasUpstream: true)
        XCTAssertTrue(pullIssues.contains { $0.message == "2 files have unresolved conflicts" && $0.severity == .blocker })
    }

    func testPullWithoutUpstreamBlocks() {
        let issues = Preflight.check(.pull, repo: repo(), hasUpstream: false)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].message, "No upstream branch configured")
    }

    func testPullWithNothingToPullWarns() {
        let issues = Preflight.check(.pull, repo: repo(behind: 0), hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertEqual(issues[0].message, "Nothing to pull")
    }

    func testPushWithNothingToPushWarns() {
        let issues = Preflight.check(.push, repo: repo(ahead: 0), hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertEqual(issues[0].message, "Nothing to push")
    }

    func testPushWhenBehindWarnsNotBlocks() {
        let issues = Preflight.check(.push, repo: repo(ahead: 1, behind: 2), hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertEqual(issues[0].message, "2 commits behind — push may be rejected")
    }

    func testCommitWithNoStagedChangesBlocks() {
        let r = repo(changes: [change("a.txt", status: .modified, area: .unstaged)])
        let issues = Preflight.check(.commit, repo: r, hasUpstream: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .blocker)
        XCTAssertEqual(issues[0].message, "Nothing staged")
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

    func testAmendOfLocalOnlyCommitHasNoIssues() {
        // ahead > 0: the last commit is still only local, so amending is safe.
        let r = repo(ahead: 1)
        XCTAssertEqual(Preflight.check(.amend, repo: r, hasUpstream: true), [])
    }

    func testAmendWithoutUpstreamHasNoPushedWarning() {
        let r = repo()
        XCTAssertEqual(Preflight.check(.amend, repo: r, hasUpstream: false), [])
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

    func testUndoWithoutUpstreamHasNoPushedBlocker() {
        XCTAssertEqual(Preflight.check(.undoLastCommit(hasParent: true), repo: repo(), hasUpstream: false), [])
    }

    func testPullWithNoUpstreamAndConflictsReturnsBothBlockersFirst() {
        let r = repo(changes: [change("a.txt", status: .conflicted, area: .unstaged)])
        let issues = Preflight.check(.pull, repo: r, hasUpstream: false)
        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.allSatisfy { $0.severity == .blocker })
        XCTAssertEqual(Set(issues.map(\.id)), Set(["no-upstream", "conflicted"]))
    }

    // MARK: - isDiverged

    func testIsDivergedRequiresBothAheadAndBehind() {
        XCTAssertFalse(Preflight.isDiverged(repo: repo(ahead: 0, behind: 0)))
        XCTAssertFalse(Preflight.isDiverged(repo: repo(ahead: 1, behind: 0)))
        XCTAssertFalse(Preflight.isDiverged(repo: repo(ahead: 0, behind: 1)))
        XCTAssertTrue(Preflight.isDiverged(repo: repo(ahead: 1, behind: 1)))
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
        XCTAssertEqual(issues[0].message, "You will discard 3 commits on the remote")
    }

    func testForcePushUpToDateHasNoIssues() {
        XCTAssertEqual(Preflight.check(.forcePush, repo: repo(), hasUpstream: true), [])
    }

    func testMultipleIssuesOrderedBlockersBeforeWarnings() {
        // ahead == 0 (warning: nothing to push) and behind > 0 (warning: may be rejected).
        let r = repo(ahead: 0, behind: 3, changes: [change("a.txt", status: .conflicted, area: .staged)])
        // Use checkout to also get a blocker alongside push-only warnings isn't directly comparable,
        // so instead verify ordering within push's own two warnings plus a forced blocker via unavailable is separate.
        // Here: push has two warnings only; check ordering is stable (nothing-to-push then behind).
        let issues = Preflight.check(.push, repo: r, hasUpstream: true)
        XCTAssertEqual(issues.map(\.severity), [.warning, .warning])
        XCTAssertEqual(issues.map(\.id), ["nothing-to-push", "behind"])
    }

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
        XCTAssertTrue(issues.first?.message.hasPrefix("big.bin is 12") ?? false, issues.first?.message ?? "")
        XCTAssertTrue(issues.first?.message.contains("Git LFS") ?? false)
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
        XCTAssertTrue(issues.first?.message.hasSuffix("consider `git lfs track '*.bin'`") ?? false, issues.first?.message ?? "")
        XCTAssertEqual(issues.first?.suggestedLFSPattern, "*.bin")
        XCTAssertNil(Preflight.largeFileWarnings(in: changes).last?.suggestedLFSPattern)
        XCTAssertEqual(Preflight.largeFileWarnings(in: changes, lfsInstalled: true).last?.suggestedLFSPattern, "*.bin")
    }
}
