import XCTest
@testable import Gitunia

/// `PaletteRows.build` is the pure row model behind the ⌘K palette — a plain function of
/// plain values, no `WorkspaceStore`/SwiftUI, so the presence/order/filtering behaviour it decides
/// can be tested directly here instead of only observable by running the GUI.
final class PaletteRowsTests: XCTestCase {
    private let repos = ["zebra", "apple", "mango"].map { PaletteRows.RepoEntry(id: $0, name: $0) }

    /// User decision: force push never offers "All" — it stays single-repository only, so bulk
    /// force-pushing is never one click away.
    func testPendingForcePush_noAllRepositoriesRow() {
        XCTAssertFalse(PaletteRows.TopLevelAction.forcePush.offersAll)
        let rows = PaletteRows.build(repositories: repos, changeFilename: "", pending: .forcePush, query: "")
        XCTAssertFalse(rows.contains(.allRepositories))
    }

    func testBranchStepEntries_deleteIsLocalNonCurrent() {
        let branches = [
            PaletteRows.BranchEntry(id: "main", name: "main", isRemote: false, isCurrent: true),
            PaletteRows.BranchEntry(id: "feature", name: "feature", isRemote: false),
            PaletteRows.BranchEntry(id: "origin/main", name: "origin/main", isRemote: true),
        ]
        XCTAssertEqual(PaletteRows.branchStepEntries(for: .deleteBranch, branches: branches, remotes: []).map(\.name), ["feature"])
    }

    /// Thousands of branches render only `branchStepLimit` rows; the rest are counted, not built.
    func testBranchStepCapsRowsAndCountsTheRest() {
        let branches = (0..<250).map { PaletteRows.BranchEntry(id: "b\($0)", name: "b\($0)", isRemote: $0 >= 200) }
        let all = PaletteRows.buildBranchStep(branches: branches, query: "")
        XCTAssertEqual(all.rows.count, PaletteRows.branchStepLimit)
        XCTAssertEqual(all.hidden, 250 - PaletteRows.branchStepLimit)
        XCTAssertEqual(all.rows.first, .branch(branches[0])) // local before remote, then by name
        let narrow = PaletteRows.buildBranchStep(branches: branches, query: "b24")
        XCTAssertEqual(narrow.hidden, 0)
        XCTAssertEqual(narrow.rows.first?.id, "branch:b24")
        XCTAssertLessThan(narrow.rows.count, PaletteRows.branchStepLimit)
    }
}
