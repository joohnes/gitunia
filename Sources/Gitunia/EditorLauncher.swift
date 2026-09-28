import AppKit
import SwiftUI
import GituniaCore

struct Editor: Identifiable, Hashable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

enum EditorLauncher {
    static let knownEditors: [Editor] = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4"),
    ]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func installedEditors() -> [Editor] {
        knownEditors.filter { isInstalled($0.bundleID) }
    }

    /// Pure decision logic behind "ask which editor to use, remember it, use it from then on":
    /// a prompt is needed when nothing is configured yet, or when the configured app has since
    /// been uninstalled — never silently falling back to the system default in either case.
    /// `isInstalled` is injected so this is testable without touching `NSWorkspace`
    /// (`Tests/GituniaTests/EditorLauncherTests.swift`).
    static func needsPrompt(configuredBundleID: String?, isInstalled: (String) -> Bool) -> Bool {
        guard let configuredBundleID else { return true }
        return !isInstalled(configuredBundleID)
    }

    /// Opens `file` in the editor with `bundleID`. Callers should route through
    /// `EditorOpenCoordinator.open` instead of calling this directly — it's the one place that
    /// decides, via `needsPrompt`, whether to ask first. This does no such check itself: it always
    /// opens in `bundleID` if given, falling back to the system default only when `bundleID` is
    /// nil (used once the coordinator already knows which editor to use).
    static func open(_ file: URL, bundleID: String?) {
        if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}

/// The one seam every "open in editor" call site routes through (`ChangesView`'s two menu items,
/// `GituniaApp`'s ⌘⇧O command, `CommandPalette`'s palette action, and History's context menu) so a
/// missing/uninstalled editor is asked about exactly once, in one place, rather than each call site
/// silently falling back to `NSWorkspace.shared.open`. Lives in the environment (like
/// `ToastCenter`) rather than a global singleton, and is presented from `ContentView` as a sheet —
/// the same pattern the codebase already uses for cross-cutting, presentation-needing state.
@MainActor
@Observable
final class EditorOpenCoordinator {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let file: URL
    }

    var pending: Request?

    /// Opens `file` immediately if `configuredBundleID` is set and still installed; otherwise
    /// records a pending request for `ContentView` to present `EditorChooserSheet` for. The sheet
    /// itself calls `open` a second time once the user picks, this time with a bundle ID that's
    /// guaranteed to satisfy `needsPrompt`.
    func open(_ file: URL, configuredBundleID: String?) {
        if EditorLauncher.needsPrompt(configuredBundleID: configuredBundleID, isInstalled: EditorLauncher.isInstalled) {
            pending = Request(file: file)
        } else {
            EditorLauncher.open(file, bundleID: configuredBundleID)
        }
    }

    /// Same decision as `open`, but for a file that may no longer exist in the working tree — a
    /// commit's file, opened from History, can have been deleted since. Toasts instead of failing
    /// silently in that case (`NSWorkspace.shared.open` on a missing file just does nothing
    /// visible). Used by History's context menu and ⌘⇧O while History is the active mode.
    func openWorkingTreeFile(_ path: String, in repoURL: URL, configuredBundleID: String?, toasts: ToastCenter) {
        let file = repoURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            toasts.post(.info("Can't open \((path as NSString).lastPathComponent)", detail: "This file no longer exists in the working tree."))
            return
        }
        open(file, configuredBundleID: configuredBundleID)
    }
}

/// Presented by `ContentView` when `EditorOpenCoordinator.pending` is set. Reuses the
/// `NSOpenPanel` pattern already in `SettingsView.chooseApp()` for "Other application…", and saves
/// the choice via `workspace.updateSettings` — the same `AppSettings.editorBundleID` Settings
/// itself reads and edits, so picking here and changing it later in Settings are the same value.
struct EditorChooserSheet: View {
    let request: EditorOpenCoordinator.Request
    var workspace: WorkspaceStore
    var coordinator: EditorOpenCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open in Editor").font(.headline)
            Text("Choose an editor for \((request.file.lastPathComponent)). Gitunia will remember this choice.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(EditorLauncher.installedEditors()) { editor in
                    Button {
                        choose(editor.bundleID)
                    } label: {
                        HStack {
                            Text(editor.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
                Button {
                    chooseOtherApplication()
                } label: {
                    HStack {
                        Text("Other application…")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { coordinator.pending = nil; dismiss() }
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func choose(_ bundleID: String) {
        var settings = workspace.config.settings
        settings.editorBundleID = bundleID
        workspace.updateSettings(settings)
        EditorLauncher.open(request.file, bundleID: bundleID)
        coordinator.pending = nil
        dismiss()
    }

    private func chooseOtherApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            choose(id)
        }
    }
}
