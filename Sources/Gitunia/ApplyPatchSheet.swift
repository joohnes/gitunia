import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GituniaCore

/// Paste or load a patch, see `git apply --check`'s verdict live, then apply it to the working
/// tree (`git apply`) or, for a `format-patch` mailbox, recreate the commits (`git am`).
struct ApplyPatchSheet: View {
    let repo: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var text: String
    @State private var check: PatchCheck?
    /// The text `check` describes — lets render tests inject a result without it being recomputed.
    @State private var checkedText: String?
    @State private var asCommits = true
    @State private var threeWay = false
    @State private var applyError: String?
    @State private var isApplying = false

    init(repo: RepositoryStore, initialText: String = "", initialCheck: PatchCheck? = nil) {
        self.repo = repo
        _text = State(initialValue: initialText)
        _check = State(initialValue: initialCheck)
        _checkedText = State(initialValue: initialCheck == nil ? nil : initialText)
    }

    private var isMailbox: Bool { check?.isMailbox ?? PatchCheck.isMailbox(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apply Patch — \(repo.repo.name)").font(.title3.bold())
                Spacer()
                Button("Choose File…", systemImage: "doc", action: chooseFile)
            }
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste a patch, choose a file, or drop a .patch onto a repository in the sidebar.")
                            .font(.callout).foregroundStyle(.tertiary).padding(12).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 220)
            checkRow
            Toggle("Apply as commits (git am)", isOn: Binding(get: { isMailbox && asCommits }, set: { asCommits = $0 }))
                .disabled(!isMailbox)
                .help(isMailbox ? "Recreates each commit with its original author and message"
                                : "Only for patches made by git format-patch (with From:/Subject: headers)")
            Toggle("3-way merge", isOn: $threeWay)
                .help("Fall back to a 3-way merge when context doesn't match; leaves conflict markers to resolve. git stages what it merges.")
            if let applyError {
                Text(applyError)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(6)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isMailbox && asCommits ? "Apply as Commits" : "Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (check?.applies == false && !threeWay))
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: text) {
            guard text != checkedText else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await repo.checkPatch(text)
            guard !Task.isCancelled else { return }
            check = result; checkedText = text; applyError = nil
        }
    }

    @ViewBuilder private var checkRow: some View {
        if let check, !check.message.isEmpty {
            Label {
                Text(check.message).lineLimit(3).textSelection(.enabled)
            } icon: {
                Image(systemName: check.applies ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(check.applies ? .green : .orange)
            }
            .font(.callout)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["patch", "diff", "txt", "eml"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents
    }

    private func apply() {
        isApplying = true
        let commits = isMailbox && asCommits
        Task {
            defer { isApplying = false }
            if let error = await repo.applyPatch(text, asCommits: commits, threeWay: threeWay) {
                applyError = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            toasts?.post(.success(commits ? "Patch applied as commits" : "Patch applied — review and stage",
                                  detail: repo.repo.name))
            dismiss()
        }
    }

    /// Sidebar drop: the first `.patch`/`.diff` file opens this sheet for `store`.
    static func handleDrop(_ urls: [URL], on store: RepositoryStore, workspace: WorkspaceStore, sheets: RepoSheets?) -> Bool {
        guard let sheets, let url = urls.first(where: { ["patch", "diff"].contains($0.pathExtension.lowercased()) }),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        workspace.select(store)
        sheets.active = .applyPatch(store, contents)
        return true
    }
}

/// History's "Export as Patch…" / "Copy as Patch" and the palette's "Copy Diff as Patch".
@MainActor
enum PatchExport {
    static func save(_ commit: CommitInfo, from repo: RepositoryStore, toasts: ToastCenter) async {
        guard let patch = await repo.formatPatch([commit.hash]).first else {
            return toasts.post(.error("Couldn't export \(commit.shortHash)"))
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = patch.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try patch.contents.write(to: url, atomically: true, encoding: .utf8) }
        catch { toasts.post(.error("Couldn't save patch", detail: error.localizedDescription)) }
    }

    static func copy(_ commit: CommitInfo, from repo: RepositoryStore, toasts: ToastCenter) async {
        guard let patch = await repo.formatPatch([commit.hash]).first else {
            return toasts.post(.error("Couldn't export \(commit.shortHash)"))
        }
        copyToPasteboard(patch.contents)
        toasts.post(.success("Copied patch", detail: commit.subject))
    }

    static func copyDiff(from repo: RepositoryStore, toasts: ToastCenter) async {
        let staged = !repo.stagedChanges.isEmpty
        let diff = await repo.diffPatch(staged: staged)
        guard !diff.isEmpty else { return toasts.post(.info("No changes to copy", detail: repo.repo.name)) }
        copyToPasteboard(diff)
        toasts.post(.success(staged ? "Copied staged diff" : "Copied unstaged diff", detail: repo.repo.name))
    }

    private static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
