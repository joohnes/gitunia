import XCTest
@testable import GituniaCore

final class PatchBuilderTests: XCTestCase {
    func testBuildsUnifiedPatchForOneHunk() {
        let hunk = Hunk(header: "@@ -1,3 +1,3 @@", lines: [
            DiffLine(kind: .context, text: "one", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .removed, text: "two", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .added, text: "TWO", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .context, text: "three", oldNumber: 3, newNumber: 3),
        ])
        XCTAssertEqual(PatchBuilder.patch(path: "dir/a.txt", hunk: hunk), """
        diff --git a/dir/a.txt b/dir/a.txt
        --- a/dir/a.txt
        +++ b/dir/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three

        """)
    }
}
