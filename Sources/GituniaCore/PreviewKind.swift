import Foundation
import UniformTypeIdentifiers

/// What kind of preview a file gets in the diff/compare views — native APIs only (see
/// `docs/file-preview-plan.md`): `NSImage` for raster/vector, Quick Look for everything else it
/// can render, plain text for the existing line-diff view, `.none` for opaque binaries.
public enum PreviewKind: Sendable, Equatable {
    case raster, vector, pdf, video, audio, quickLook, text, none

    public static func kind(for path: String) -> PreviewKind {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            // No extension (e.g. `Makefile`) or an extension UTType doesn't know: treat as text
            // unless we have positive evidence otherwise — there's nothing else to go on.
            return .text
        }
        if type.conforms(to: .svg) { return .vector }
        if type.conforms(to: .image) { return .raster }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if quickLookTypes.contains(where: { type.conforms(to: $0) }) { return .quickLook }
        if type.conforms(to: .text) { return .text }
        return .none
    }

    /// Office/archive/font/etc. formats with no native `NSImage`/text rendering but a system Quick
    /// Look generator. `UTType("…")` for identifiers with no static `UTType` constant.
    private static let quickLookTypes: [UTType] = [
        .rtf, .epub, .zip, .font,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("org.openxmlformats.spreadsheetml.sheet"),
        UTType("org.openxmlformats.presentationml.presentation"),
    ].compactMap { $0 }

    public static let maxPreviewBytes = 50_000_000

    public static func canPreview(kind: PreviewKind, size: Int?) -> Bool {
        guard kind != .none, kind != .text else { return false }
        guard let size else { return true }
        return size <= maxPreviewBytes
    }
}
