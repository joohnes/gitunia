import AppKit
import GituniaCore
import UniformTypeIdentifiers

@MainActor
enum WorkspacePanels {
    private static var workspaceType: UTType {
        UTType(filenameExtension: WorkspaceFile.fileExtension) ?? .json
    }

    static func chooseWorkspaceFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [workspaceType]
        panel.message = "Choose a Gitunia workspace"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(message: String, prompt: String, in directory: URL? = nil, canCreateDirectories: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        if canCreateDirectories { panel.canCreateDirectories = true }
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [workspaceType]
        panel.nameFieldStringValue = "\(suggestedName).\(WorkspaceFile.fileExtension)"
        panel.message = "Save this workspace to a file you can open again later"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Workspace membership actions, shared by the File menu, ⌘K and the empty state so each one
/// behaves and reports the same way wherever it is triggered.
@MainActor
enum WorkspaceActions {
    static func addFolder(to store: WorkspaceStore, toasts: ToastCenter) {
        guard let url = WorkspacePanels.chooseFolder(message: "Choose a git repository to add", prompt: "Add") else { return }
        Task {
            do { let repo = try await store.addRepository(url); toasts.post(.success("Added \(repo.repo.name)")) }
            catch { toasts.post(.error("Can't add folder", detail: error.localizedDescription)) }
        }
    }

    static func addReposInFolder(to store: WorkspaceStore, toasts: ToastCenter) {
        guard let url = WorkspacePanels.chooseFolder(
            message: "Choose a folder — every repository in it (up to 3 levels deep) joins this workspace, including ones added later",
            prompt: "Add Repos"
        ) else { return }
        Task {
            let before = store.repositories.count
            await store.addFolder(url)
            let added = store.repositories.count - before
            toasts.post(added > 0
                ? .success("Linked \(url.lastPathComponent)", detail: "\(added) repositor\(added == 1 ? "y" : "ies") added")
                : .info("Linked \(url.lastPathComponent)", detail: "No repositories found yet — new ones will appear automatically"))
        }
    }

    @discardableResult
    static func saveAs(_ store: WorkspaceStore, toasts: ToastCenter) -> Bool {
        let suggested = store.isUntitled ? "Workspace" : store.displayName
        guard let url = WorkspacePanels.chooseSaveLocation(suggestedName: suggested) else { return false }
        do { try store.saveAs(url); return true }
        catch { toasts.post(.error("Couldn't save workspace", detail: error.localizedDescription)); return false }
    }

    static func remove(_ repo: RepositoryStore, from store: WorkspaceStore, toasts: ToastCenter) {
        guard let removal = store.remove(repo) else { return }
        let url = store.fileURL
        toasts.post(Toast(style: .success, title: "Removed \(repo.repo.name)",
                          detail: "Only from this workspace — nothing on disk changed",
                          action: ToastAction(title: "Undo") {
            Task { @MainActor in await undoRemoval(removal, in: store, ifStillAt: url) }
        }))
    }

    /// The Undo toast outlives the workspace it came from: if this window has since opened another
    /// workspace, undoing would write the removal into the wrong file, and if the file is gone
    /// ("Don't Save" on an untitled workspace) it would recreate it — so it does nothing instead.
    static func undoRemoval(_ removal: WorkspaceRemoval, in store: WorkspaceStore, ifStillAt url: URL?) async {
        guard let url, store.fileURL == url, FileManager.default.fileExists(atPath: url.path) else { return }
        await store.undo(removal)
    }
}
