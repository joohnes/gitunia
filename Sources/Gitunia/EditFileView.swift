import SwiftUI
import GituniaCore

/// Tracks whether `EditFileView` currently has unsaved edits, and lets whoever owns navigation
/// (`ContentView`) ask "is it safe to do this" before switching file/repo/mode, offering
/// Save/Discard/Cancel when it isn't. This class knows nothing about text or files — it only
/// coordinates: `EditFileView` registers what "save" and "discard" actually mean (they need the
/// specific text buffer and target file) as closures while it's on screen, and clears them again
/// when it isn't. One instance lives in `ContentView` (`@State`) and is handed down to `DiffView`
/// (which owns the Edit/Done toggle) and `EditFileView` (which owns the text buffer).
///
/// See `ContentView`'s guarded bindings for where this actually intercepts navigation — a plain
/// `.onDisappear` on `DiffView` can't do it, because `DiffView` is recreated in place (same
/// position in the view tree, new `change`/`repo` parameters) when the selected file or repository
/// changes, rather than torn down and rebuilt: the switch already happened by the time
/// `.onDisappear` would fire.
@MainActor
@Observable
final class EditSession {
    private(set) var isDirty = false
    /// Set by `EditFileView` while it's on screen; returns whether the save (and thus a pending
    /// navigation) may proceed. `nil` when nothing is being edited.
    var saveAction: (() async -> Bool)?
    /// Drops in-memory edits without writing anything. Not required to reset any view state itself
    /// — the editor is about to be unmounted by the navigation this unblocks.
    var discardAction: (() -> Void)?

    private(set) var pendingNavigation: (() -> Void)?
    var showConfirm = false

    func setDirty(_ dirty: Bool) {
        isDirty = dirty
    }

    /// Runs `action` immediately if there's nothing to lose; otherwise stashes it and asks via
    /// `showConfirm` (bound to a `.confirmationDialog` in `ContentView`).
    func guardNavigation(_ action: @escaping () -> Void) {
        guard isDirty else {
            action()
            return
        }
        pendingNavigation = action
        showConfirm = true
    }

    func confirmSave() {
        guard let saveAction else {
            resolve()
            return
        }
        Task {
            let ok = await saveAction()
            showConfirm = false
            // A failed save (permission denied, or the user backed out of the concurrent-change
            // dialog) leaves the pending navigation in place — the file is still unsaved, so
            // silently discarding or navigating away would be exactly the data loss this guard
            // exists to prevent. The dialog just closes; the user can retry Done/switch.
            if ok { resolve() }
        }
    }

    func confirmDiscard() {
        discardAction?()
        resolve()
    }

    func cancelNavigation() {
        pendingNavigation = nil
        showConfirm = false
    }

    private func resolve() {
        let action = pendingNavigation
        pendingNavigation = nil
        isDirty = false
        showConfirm = false
        action?()
    }
}

/// The "Simple editing" text view itself (spec item 5): a plain, monospaced, editable view of a
/// file's working-tree copy, swapped in by `DiffView` in place of the diff when the user presses
/// Edit. Owns all the disk I/O for this file — load, the concurrent-change check on save, and the
/// atomic, line-ending-preserving write. `DiffView` only owns the Edit/Done toggle and the
/// editability check that enables it.
struct EditFileView: View {
    let fileURL: URL
    var editSession: EditSession
    /// Bumps `DiffView.reloadToken` so the diff reflects the new content once the user returns to
    /// it — FSEvents will also notice the write, but that's a workspace-wide status refresh with no
    /// guarantee of ordering against this view's own state, so this view reloads its own diff
    /// explicitly instead of hoping the watcher gets there first.
    var onSaved: () -> Void
    /// Called when the initial load fails (deleted/permission-denied/binary-since-checked) — kicks
    /// back to the diff. No confirmation needed: nothing was ever loaded into the buffer, so there
    /// are no edits to lose.
    var onLoadFailed: () -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var text = ""
    @State private var initialText = ""
    @State private var format = FileEditor.TextFormat(lineEnding: .lf, hasTrailingNewline: true)
    @State private var loadedSnapshot: FileEditor.Snapshot?
    @State private var isLoaded = false
    @State private var showConflictDialog = false
    @State private var conflictContinuation: CheckedContinuation<ConflictResolution, Never>?

    private enum ConflictResolution { case overwrite, reloadDiscard, cancel }

    var body: some View {
        Group {
            if isLoaded {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
            } else {
                ProgressView()
            }
        }
        // A visually-hidden button is the standard way to attach a keyboard shortcut that isn't
        // tied to a visible toolbar/menu item — SwiftUI still registers it via the responder chain.
        .background(
            Button("Save") { Task { _ = await save() } }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
        )
        .onAppear(perform: load)
        .onDisappear {
            editSession.saveAction = nil
            editSession.discardAction = nil
            editSession.setDirty(false)
        }
        .onChange(of: text) { _, newValue in
            editSession.setDirty(newValue != initialText)
        }
        .confirmationDialog(
            "This file changed on disk since you started editing",
            isPresented: $showConflictDialog,
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) { resumeConflict(.overwrite) }
            Button("Discard my edits and reload") { resumeConflict(.reloadDiscard) }
            Button("Cancel", role: .cancel) { resumeConflict(.cancel) }
        } message: {
            Text("Something wrote to \(fileURL.lastPathComponent) while you were editing it.")
        }
    }

    private func resumeConflict(_ resolution: ConflictResolution) {
        conflictContinuation?.resume(returning: resolution)
        conflictContinuation = nil
    }

    private func load() {
        // M9 defense in depth: `DiffView` already disables Edit for a symlink (via
        // `FileEditor.editability`), so this shouldn't normally be reachable for one — but this
        // view does its own disk I/O independently, so it re-checks rather than trusting the
        // caller, exactly like the concurrent-modification check below re-checks disk state rather
        // than trusting `loadedSnapshot`. Never reads through the link to find out.
        guard !FileEditor.isSymlink(at: fileURL) else {
            toasts.post(.error(fileURL.lastPathComponent, detail: "This is a symlink"))
            onLoadFailed()
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            toasts.post(.error(fileURL.lastPathComponent, detail: "Could not read file"))
            onLoadFailed()
            return
        }
        guard applyLoadedData(data) else {
            toasts.post(.error(fileURL.lastPathComponent, detail: "File is not valid UTF-8"))
            onLoadFailed()
            return
        }
        editSession.saveAction = { await save() }
        editSession.discardAction = {}
    }

    /// Loads `data` into the buffer as the new baseline (used both for the initial load and for
    /// "Discard my edits and reload"). Returns false if the bytes aren't valid UTF-8, leaving
    /// existing state untouched.
    @discardableResult
    private func applyLoadedData(_ data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        format = FileEditor.TextFormat.detect(in: string)
        let normalized = string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = normalized
        initialText = normalized
        loadedSnapshot = FileEditor.Snapshot(modificationDate: modificationDate(at: fileURL) ?? Date(), content: data)
        isLoaded = true
        editSession.setDirty(false)
        return true
    }

    private func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @MainActor
    private func save() async -> Bool {
        guard let baseline = loadedSnapshot else { return false }
        // Re-check for a symlink here too: something could have replaced the file with one after
        // load (an agent, a race) but before this save — never read through it to build the
        // concurrent-change snapshot below.
        guard !FileEditor.isSymlink(at: fileURL) else {
            toasts.post(.error(fileURL.lastPathComponent, detail: "This is now a symlink — refusing to overwrite it"))
            return false
        }
        guard let currentData = try? Data(contentsOf: fileURL), let currentMTime = modificationDate(at: fileURL) else {
            toasts.post(.error(fileURL.lastPathComponent, detail: "File was deleted or is no longer readable"))
            return false
        }
        let current = FileEditor.Snapshot(modificationDate: currentMTime, content: currentData)
        if FileEditor.concurrentChange(loaded: baseline, current: current) == .conflict {
            switch await resolveConflict() {
            case .cancel:
                return false
            case .reloadDiscard:
                applyLoadedData(currentData)
                return false
            case .overwrite:
                break
            }
        }

        let bytes = FileEditor.serialize(text, format: format)
        do {
            try bytes.write(to: fileURL, options: .atomic)
        } catch {
            toasts.post(.error(fileURL.lastPathComponent, detail: "Could not save: \(error.localizedDescription)"))
            return false
        }
        loadedSnapshot = FileEditor.Snapshot(modificationDate: modificationDate(at: fileURL) ?? Date(), content: bytes)
        initialText = text
        editSession.setDirty(false)
        onSaved()
        return true
    }

    private func resolveConflict() async -> ConflictResolution {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            showConflictDialog = true
        }
    }
}
