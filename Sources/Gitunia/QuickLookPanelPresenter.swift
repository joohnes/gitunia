import AppKit
import Quartz

/// Backs `QLPreviewPanel.shared()`'s single-item data source for the Changes list's Space
/// shortcut (docs/file-preview-plan.md step 3) — same "select a file, hit space" as Finder. Not
/// wired into the full `QLPreviewPanelController` responder chain (no app-wide preview-panel
/// ownership needed for a single toggle); `presentOrDismiss` shows/hides the shared panel directly.
@MainActor
final class QuickLookPanelPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPanelPresenter()
    private var url: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }

    /// Closes the panel if it's already open, otherwise opens (or retargets) it at `fileURL`.
    func presentOrDismiss(_ fileURL: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        url = fileURL
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}
