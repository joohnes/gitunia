import XCTest
import SwiftUI
import AppKit
import Quartz
@testable import Gitunia
@testable import GituniaCore

/// Offscreen visual verification for `FilePreviewView`/`QuickLookPane` (docs/file-preview-plan.md
/// step 4): raster before/after in side-by-side mode, an SVG (same `NSImage` path as raster), a
/// PDF (Quick Look), and the icon/size/UTI fallback for an opaque binary.
///
/// Disabled by default:
///   RUN_PALETTE_RENDER_TESTS=1 swift test --filter FilePreviewRenderTests
@MainActor
final class FilePreviewRenderTests: RenderTestCase {
    private func render(_ view: some View, name: String, size: CGSize) async throws -> String {
        try await renderPNG(view, name: name, size: size)
    }

    private func makeRepo() async throws -> URL {
        let url = try TestRepo.fixedRoot("file-preview")
        return try await TestRepo.make(at: url, files: ["README.md": "hello\n"])
    }

    /// A small solid-color PNG, via `NSBitmapImageRep` — no asset bundle needed.
    private func pngData(color: NSColor, size: Int = 40) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// A minimal one-page PDF via `NSView.dataWithPDF(inside:)` — no PDFKit/hand-rolled bytes needed.
    private func pdfData(color: NSColor) -> Data {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return view.dataWithPDF(inside: view.bounds)
    }

    // MARK: - (a) Raster before/after — side by side

    func testRender_rasterSideBySide() async throws {
        let url = try await makeRepo()
        let file = url.appendingPathComponent("photo.png")
        try pngData(color: .systemRed).write(to: file)
        let git = GitRunner()
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "add photo"])
        try pngData(color: .systemBlue).write(to: file)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let before = await store.previewFile(path: "photo.png", at: "HEAD")
        let after = await store.previewFile(path: "photo.png", at: nil)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)

        let view = FilePreviewView(repo: store, path: "photo.png", kind: .raster, before: before, after: after)
        let path = try await render(view, name: "file-preview-01-raster-side-by-side", size: CGSize(width: 700, height: 400))
        try assertNonBlankPNG(at: path)
    }

    // MARK: - (b) SVG — same NSImage path as raster, different UTType branch

    func testRender_svgVector() async throws {
        let url = try await makeRepo()
        let file = url.appendingPathComponent("shape.svg")
        let before = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='red'/></svg>"
        let after = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='blue'/><rect x='10' y='10' width='20' height='20' fill='green'/></svg>"
        try before.write(to: file, atomically: true, encoding: .utf8)
        let git = GitRunner()
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "add shape"])
        try after.write(to: file, atomically: true, encoding: .utf8)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let beforeURL = await store.previewFile(path: "shape.svg", at: "HEAD")
        let afterURL = await store.previewFile(path: "shape.svg", at: nil)
        XCTAssertEqual(PreviewKind.kind(for: "shape.svg"), .vector)

        let view = FilePreviewView(repo: store, path: "shape.svg", kind: .vector, before: beforeURL, after: afterURL)
        let path = try await render(view, name: "file-preview-02-svg", size: CGSize(width: 700, height: 400))
        try assertNonBlankPNG(at: path)
    }

    // MARK: - (c) PDF — Quick Look

    /// Quick Look may not composite offscreen (same caveat `DiffFixesRenderTests`/the plan note
    /// for AppKit controls without a real key window) — this asserts no crash and that a
    /// `QLPreviewView` is actually in the rendered hierarchy; if the PNG turns out blank, that's
    /// recorded via `print`, not failed on, per the plan.
    func testRender_pdfQuickLook() async throws {
        let url = try await makeRepo()
        let file = url.appendingPathComponent("doc.pdf")
        try pdfData(color: .systemRed).write(to: file)
        let git = GitRunner()
        _ = try await git.run(["add", "."], in: url)
        _ = try await TestRepo.commit(at: url, args: ["-q", "-m", "add doc"])
        try pdfData(color: .systemBlue).write(to: file)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let before = await store.previewFile(path: "doc.pdf", at: "HEAD")
        let after = await store.previewFile(path: "doc.pdf", at: nil)
        XCTAssertEqual(PreviewKind.kind(for: "doc.pdf"), .pdf)

        let view = FilePreviewView(repo: store, path: "doc.pdf", kind: .pdf, before: before, after: after)
        let (hosting, window) = hostOffscreen(view, size: CGSize(width: 700, height: 400), appearance: .aqua)
        defer { window.orderOut(nil) }
        await pumpLayout(hosting, ticks: 20)
        XCTAssertTrue(containsQLPreviewView(hosting), "Expected a QLPreviewView in the rendered hierarchy")
        let path = try writePNG(hosting, name: "file-preview-03-pdf-quicklook")
        if try hasMultipleColors(at: path) {
            print("Quick Look composited offscreen: \(path)")
        } else {
            print("Quick Look did NOT composite offscreen for \(path) — known AppKit/QLPreviewView limitation (no real key window here); the view hierarchy check above is what this test actually asserts.")
        }
    }

    private func containsQLPreviewView(_ view: NSView) -> Bool {
        if view is QLPreviewView { return true }
        return view.subviews.contains { containsQLPreviewView($0) }
    }

    // MARK: - (d) Unknown binary — icon/size/UTI fallback

    func testRender_unknownBinaryFallback() async throws {
        let url = try await makeRepo()
        let file = url.appendingPathComponent("data.bin")
        try Data((0..<256).map { UInt8($0 % 256) }).write(to: file)

        let store = RepositoryStore(url: url)
        await store.refreshStatus()
        let after = await store.previewFile(path: "data.bin", at: nil)
        XCTAssertNotNil(after)
        XCTAssertEqual(PreviewKind.kind(for: "data.bin"), .none)

        let view = FilePreviewView(repo: store, path: "data.bin", kind: .none, before: nil, after: after)
        let path = try await render(view, name: "file-preview-04-unknown-binary-fallback", size: CGSize(width: 500, height: 300))
        try assertNonBlankPNG(at: path)
    }

    // MARK: - Helpers

    /// Whether the PNG at `path` has more than one distinct sampled color — a crude "something
    /// was actually drawn" signal, same spirit as the plan's "non-empty pixels" check.
    private func hasMultipleColors(at path: String) throws -> Bool {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let rep = NSBitmapImageRep(data: data) else { return false }
        var colors = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 20)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = UInt32(color.redComponent * 255), g = UInt32(color.greenComponent * 255), b = UInt32(color.blueComponent * 255)
                colors.insert((r << 16) | (g << 8) | b)
            }
        }
        return colors.count > 1
    }

    /// Asserts the PNG at `path` isn't uniformly one color.
    private func assertNonBlankPNG(at path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try hasMultipleColors(at: path), "PNG at \(path) looks blank (a single solid color)", file: file, line: line)
    }
}
