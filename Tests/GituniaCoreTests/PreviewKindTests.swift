import XCTest
@testable import GituniaCore

final class PreviewKindTests: XCTestCase {
    func testRaster() {
        for name in ["a.png", "a.JPG", "a.jpeg", "a.heic", "a.webp", "a.gif", "a.tiff", "a.bmp"] {
            XCTAssertEqual(PreviewKind.kind(for: name), .raster, name)
        }
    }

    func testVector() {
        XCTAssertEqual(PreviewKind.kind(for: "logo.svg"), .vector)
    }

    func testPDF() {
        XCTAssertEqual(PreviewKind.kind(for: "doc.pdf"), .pdf)
    }

    func testVideo() {
        XCTAssertEqual(PreviewKind.kind(for: "clip.mov"), .video)
        XCTAssertEqual(PreviewKind.kind(for: "clip.mp4"), .video)
    }

    func testAudio() {
        XCTAssertEqual(PreviewKind.kind(for: "song.mp3"), .audio)
        XCTAssertEqual(PreviewKind.kind(for: "song.m4a"), .audio)
    }

    func testQuickLook() {
        for name in ["report.docx", "sheet.xlsx", "archive.zip", "font.ttf"] {
            XCTAssertEqual(PreviewKind.kind(for: name), .quickLook, name)
        }
    }

    func testText() {
        for name in ["main.swift", "notes.md", "data.json", "config.yml", "Makefile"] {
            XCTAssertEqual(PreviewKind.kind(for: name), .text, name)
        }
    }

    func testNone() {
        for name in ["blob.bin", "data.dat", "obj.o"] {
            XCTAssertEqual(PreviewKind.kind(for: name), .none, name)
        }
    }

    func testCanPreviewRespectsSizeCap() {
        XCTAssertTrue(PreviewKind.canPreview(kind: .raster, size: PreviewKind.maxPreviewBytes))
        XCTAssertFalse(PreviewKind.canPreview(kind: .raster, size: PreviewKind.maxPreviewBytes + 1))
        XCTAssertTrue(PreviewKind.canPreview(kind: .raster, size: nil))
    }

    func testCanPreviewFalseForTextAndNone() {
        XCTAssertFalse(PreviewKind.canPreview(kind: .text, size: 10))
        XCTAssertFalse(PreviewKind.canPreview(kind: .none, size: 10))
    }
}
