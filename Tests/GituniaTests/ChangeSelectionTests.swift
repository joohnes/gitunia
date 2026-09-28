import XCTest
import GituniaCore
@testable import Gitunia

final class ChangeSelectionTests: XCTestCase {
    private func change(_ path: String, staged: Bool = false, untracked: Bool = false) -> FileChange {
        FileChange(path: path, status: untracked ? .untracked : .modified, area: staged ? .staged : .unstaged)
    }

    // MARK: - focusedChange

    func testFocusedChange_plainClickReplacingSelection() {
        let a = change("a.swift"), b = change("b.swift")
        XCTAssertEqual(ChangeSelection.focusedChange(old: [a], new: [b], previousFocused: a), b)
    }

    func testFocusedChange_cmdClickExtendingSelectionFocusesTheNewMember() {
        let a = change("a.swift"), b = change("b.swift")
        XCTAssertEqual(ChangeSelection.focusedChange(old: [a], new: [a, b], previousFocused: a), b)
    }

    func testFocusedChange_deselectingKeepsPreviousFocusIfStillPresent() {
        let a = change("a.swift"), b = change("b.swift"), c = change("c.swift")
        XCTAssertEqual(ChangeSelection.focusedChange(old: [a, b, c], new: [a, b], previousFocused: b), b)
    }

    func testFocusedChange_deselectingThePreviousFocusFallsBackToAnotherMember() {
        let a = change("a.swift"), b = change("b.swift")
        XCTAssertEqual(ChangeSelection.focusedChange(old: [a, b], new: [b], previousFocused: a), b)
    }

    func testFocusedChange_emptySelectionHasNoFocus() {
        let a = change("a.swift")
        XCTAssertNil(ChangeSelection.focusedChange(old: [a], new: [], previousFocused: a))
    }

    func testFocusedChange_multipleAddedPicksDeterministically() {
        let a = change("a.swift"), b = change("b.swift"), c = change("c.swift")
        // sorted by path, so "a.swift" wins regardless of Set iteration order
        XCTAssertEqual(ChangeSelection.focusedChange(old: [], new: [c, a, b], previousFocused: nil), a)
    }

    // MARK: - bulkTargets

    func testBulkTargets_splitsByArea() {
        let staged = change("staged.swift", staged: true)
        let unstaged = change("unstaged.swift")
        let untracked = change("new.swift", untracked: true)
        let bulk = ChangeSelection.bulkTargets(for: [staged, unstaged, untracked])
        XCTAssertEqual(bulk.toStage.map(\.path), ["new.swift", "unstaged.swift"])
        XCTAssertEqual(bulk.toUnstage.map(\.path), ["staged.swift"])
    }

    func testBulkTargets_allStagedMeansOnlyUnstageTargets() {
        let a = change("a.swift", staged: true), b = change("b.swift", staged: true)
        let bulk = ChangeSelection.bulkTargets(for: [a, b])
        XCTAssertTrue(bulk.toStage.isEmpty)
        XCTAssertEqual(bulk.toUnstage.map(\.path), ["a.swift", "b.swift"])
    }

    func testBulkTargets_emptySelectionHasNoTargets() {
        let bulk = ChangeSelection.bulkTargets(for: [])
        XCTAssertTrue(bulk.toStage.isEmpty)
        XCTAssertTrue(bulk.toUnstage.isEmpty)
    }

    // MARK: - reconcile (M6)

    func testReconcile_exactMatchSurvivesUntouched() {
        let a = change("a.swift")
        XCTAssertEqual(ChangeSelection.reconcile(a, changeSet: [a], changes: [a]), a)
    }

    /// A file with both a staged and an unstaged hunk is two distinct `FileChange`s sharing a
    /// path. If the selected one's exact struct is gone (its `status` changed) but another entry
    /// for the same path *and area* still exists, that's the one to follow — not whichever one
    /// happens to be first in `changes`.
    func testReconcile_prefersSameAreaOverArbitraryPathMatch() {
        let stagedOld = FileChange(path: "a.swift", status: .modified, area: .staged)
        let stagedNew = FileChange(path: "a.swift", status: .added, area: .staged)
        let unstagedSamePath = FileChange(path: "a.swift", status: .modified, area: .unstaged)
        // `unstagedSamePath` sorts/iterates before `stagedNew` in some Set orderings — reconcile
        // must not pick it just because it's a path match found first.
        let changes = [unstagedSamePath, stagedNew]
        XCTAssertEqual(ChangeSelection.reconcile(stagedOld, changeSet: Set(changes), changes: changes), stagedNew)
    }

    func testReconcile_fallsBackToAnyAreaWhenSameAreaGone() {
        let stagedOld = FileChange(path: "a.swift", status: .modified, area: .staged)
        let unstagedNew = FileChange(path: "a.swift", status: .modified, area: .unstaged)
        let changes = [unstagedNew]
        XCTAssertEqual(ChangeSelection.reconcile(stagedOld, changeSet: Set(changes), changes: changes), unstagedNew)
    }

    func testReconcile_pathGoneEntirelyReturnsNil() {
        let a = change("a.swift")
        let other = change("b.swift")
        XCTAssertNil(ChangeSelection.reconcile(a, changeSet: [other], changes: [other]))
    }
}
