import XCTest
@testable import GituniaCore

final class PreviewKindTests: XCTestCase {
    func testCanPreviewRespectsSizeCap() {
        XCTAssertTrue(PreviewKind.canPreview(kind: .raster, size: PreviewKind.maxPreviewBytes))
        XCTAssertFalse(PreviewKind.canPreview(kind: .raster, size: PreviewKind.maxPreviewBytes + 1))
        XCTAssertTrue(PreviewKind.canPreview(kind: .raster, size: nil))
    }

    /// UTType calls `.ts` a video; TypeScript must still get the text diff.
    func testTypeScriptIsTextNotVideo() {
        XCTAssertEqual(PreviewKind.kind(for: "src/app.ts"), .text)
        XCTAssertEqual(PreviewKind.kind(for: "clip.mp4"), .video)
    }
}
