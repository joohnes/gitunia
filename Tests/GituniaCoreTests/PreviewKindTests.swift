import XCTest
@testable import GituniaCore

final class PreviewKindTests: XCTestCase {
    func testCanPreviewRespectsSizeCap() {
        XCTAssertTrue(PreviewKind.canPreview(kind: .raster, size: PreviewKind.maxPreviewBytes))
        XCTAssertFalse(PreviewKind.canPreview(kind: .raster, size: PreviewKind.maxPreviewBytes + 1))
        XCTAssertTrue(PreviewKind.canPreview(kind: .raster, size: nil))
    }
}
