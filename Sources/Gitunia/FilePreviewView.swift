import SwiftUI
import GituniaCore
import Quartz

/// `NSViewRepresentable` over Quick Look's own renderer (`QLPreviewView`) — same widget Finder
/// uses for Space, so PDF, video, audio, and every other system-generator format (docs, zips,
/// fonts…) render for free. See `docs/file-preview-plan.md` step 3.
struct QuickLookPane: NSViewRepresentable {
    var url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL?
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Reassigning the same URL restarts playback for video/audio, so only touch it on a real change.
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL?
    }
}

/// Which mode raster/vector previews compare in. Persisted like any other diff-viewing preference
/// (`DiffView`'s `mode`/`wrap`).
enum FilePreviewCompareMode: String, CaseIterable {
    case sideBySide, swipe, onion
}

/// Replaces `ImagePreviewView`: one view for every previewable kind (`PreviewKind`), fed two
/// already-resolved URLs — `before`/`after` — by the caller (`DiffView`'s working-tree branch,
/// `FileDiffPane`'s commit/compare branch). `kind` picks the rendering strategy; pass `.none`
/// (or a kind `PreviewKind.canPreview` rejected for size) to get the icon/size/UTI fallback.
struct FilePreviewView: View {
    var repo: RepositoryStore
    var path: String
    var kind: PreviewKind
    var before: URL?
    var after: URL?
    var afterTitle: String = "After (working tree)"

    @State private var beforeImage: NSImage?
    @State private var afterImage: NSImage?
    @State private var imagesLoaded = false
    @AppStorage("filePreview.compareMode") private var mode: FilePreviewCompareMode = .sideBySide
    @State private var onionOpacity: Double = 0.5
    @State private var swipeFraction: Double = 0.5

    var body: some View {
        Group {
            switch kind {
            case .raster, .vector: rasterBody
            case .pdf, .video, .audio, .quickLook: quickLookBody
            case .text, .none: fallbackBody
            }
        }
        .task(id: "\(before?.path ?? "-")|\(after?.path ?? "-")") {
            guard kind == .raster || kind == .vector else { return }
            imagesLoaded = false
            beforeImage = before.flatMap(NSImage.init(contentsOf:))
            afterImage = after.flatMap(NSImage.init(contentsOf:))
            imagesLoaded = true
        }
    }

    // MARK: - Raster/vector

    @ViewBuilder
    private var rasterBody: some View {
        VStack(spacing: 8) {
            if before != nil && after != nil {
                Picker("Mode", selection: $mode) {
                    Text("Side by side").tag(FilePreviewCompareMode.sideBySide)
                    Text("Swipe").tag(FilePreviewCompareMode.swipe)
                    Text("Onion").tag(FilePreviewCompareMode.onion)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            Group {
                if !imagesLoaded {
                    ProgressView()
                } else if before != nil && after != nil {
                    switch mode {
                    case .sideBySide: sideBySidePanes
                    case .swipe: swipePane
                    case .onion: onionPane
                    }
                } else {
                    singlePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    private var sideBySidePanes: some View {
        HStack(spacing: 16) {
            imagePane("Before (HEAD)", beforeImage)
            imagePane(after == nil ? "After (deleted)" : afterTitle, afterImage)
        }
    }

    /// Only one side exists (added/deleted, or untracked with no HEAD copy) — no comparison mode
    /// applies, just the one image.
    private var singlePane: some View {
        imagePane(before == nil ? (after == nil ? "No image" : afterTitle) : "Before (HEAD)", beforeImage ?? afterImage)
    }

    private var swipePane: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                fittedImage(beforeImage).frame(width: geo.size.width, height: geo.size.height)
                fittedImage(afterImage)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(Rectangle().path(in: CGRect(x: 0, y: 0, width: geo.size.width * swipeFraction, height: geo.size.height)))
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: geo.size.width * swipeFraction - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    swipeFraction = min(max(value.location.x / geo.size.width, 0), 1)
                }
            )
        }
    }

    private var onionPane: some View {
        VStack(spacing: 8) {
            ZStack {
                fittedImage(beforeImage)
                fittedImage(afterImage).opacity(onionOpacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Slider(value: $onionOpacity, in: 0...1).frame(maxWidth: 320)
        }
    }

    private func imagePane(_ title: String, _ image: NSImage?) -> some View {
        VStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let image {
                fittedImage(image)
                Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView("No image", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fittedImage(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).background(checkerboard)
        } else {
            checkerboard
        }
    }

    private var checkerboard: some View { Color.secondary.opacity(0.08) }

    // MARK: - Quick Look kinds

    private var quickLookBody: some View {
        HStack(spacing: 16) {
            if let before { quickLookPane("Before (HEAD)", before) }
            if let after { quickLookPane(afterTitle, after) }
            if before == nil && after == nil {
                ContentUnavailableView("No preview", systemImage: "doc.questionmark")
            }
        }
    }

    private func quickLookPane(_ title: String, _ url: URL) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            QuickLookPane(url: url)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fallback (opaque binary, or over the size cap)

    private var fallbackURL: URL? { after ?? before }

    private var fallbackBody: some View {
        VStack(spacing: 10) {
            if let fallbackURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fallbackURL.path))
                    .resizable().frame(width: 64, height: 64)
            }
            Text((path as NSString).lastPathComponent).font(.callout).lineLimit(1)
            HStack(spacing: 6) {
                if let fileSizeText { Text(fileSizeText) }
                if let utiText { Text(utiText) }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if let fallbackURL {
                HStack {
                    Button("Open in Default App") { NSWorkspace.shared.open(fallbackURL) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fallbackURL]) }
                }
            } else {
                ContentUnavailableView("No preview", systemImage: "doc.questionmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var fileSizeText: String? {
        guard let fallbackURL, let size = try? FileManager.default.attributesOfItem(atPath: fallbackURL.path)[.size] as? Int else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var utiText: String? {
        guard let fallbackURL else { return nil }
        return (try? fallbackURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
    }
}
