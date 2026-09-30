import XCTest
import GituniaCore
@testable import Gitunia

final class ChangeSelectionTests: XCTestCase {
    private func change(_ path: String, staged: Bool = false, untracked: Bool = false) -> FileChange {
        FileChange(path: path, status: untracked ? .untracked : .modified, area: staged ? .staged : .unstaged)
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

    // MARK: - reconcile (M6)

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
        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        XCTAssertEqual(ChangeSelection.reconcile(stagedOld, byID: byID), stagedNew)
    }
}
