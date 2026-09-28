import SwiftUI
import GituniaCore

/// Rewrites HEAD's message only (`RepositoryStore.rewordHead`) — staged changes stay staged.
/// Opened from History's HEAD row and ⌘K "Reword Last Commit…", both via `RepoSheets`.
struct RewordCommitSheet: View {
    let repo: RepositoryStore
    let stripTrailers: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var title = ""
    @State private var body_ = ""
    @State private var loaded = false
    /// HEAD's body before prefill stripped agent trailers — backs the "Undo" note, as in `CommitBox`.
    @State private var unstrippedBody: String?
    @State private var keepTrailers = false
    @State private var error: String?
    @State private var isRewording = false

    /// HEAD is already on its upstream (nothing ahead), so rewording means a force push.
    private var isPushed: Bool { repo.hasUpstream && repo.repo.ahead == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reword Commit — \(repo.repo.name)").font(.title3.bold())
            if isPushed {
                Label("This commit is already on \(repo.upstreamRemote ?? "origin")/\(repo.upstreamBranch ?? repo.repo.branch ?? "") — rewording rewrites history; you'll need a force push",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            TextField("Commit title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $body_)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let original = unstrippedBody {
                let n = TrailerStripper.findings(in: original).count
                HStack(spacing: 4) {
                    Text("Removed \(n) agent trailer\(n == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Undo") { body_ = original; unstrippedBody = nil; keepTrailers = true }.buttonStyle(.link)
                }
                .font(.caption)
            }
            if let error {
                Text(error).font(.system(.caption, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled).lineLimit(6)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reword", action: reword)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || isRewording || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            guard let last = await repo.lastCommitMessage() else { return }
            let seeded = stripTrailers ? TrailerStripper.strip(last) : last
            title = seeded.title
            body_ = seeded.body
            unstrippedBody = seeded.body == last.body ? nil : last.body
            loaded = true
        }
    }

    private func reword() {
        isRewording = true
        Task {
            defer { isRewording = false }
            guard await repo.rewordHead(CommitMessage(title: title, body: body_), stripTrailers: stripTrailers && !keepTrailers) else {
                error = repo.lastError?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Reword failed"
                return
            }
            toasts?.post(.success("Reworded \(repo.repo.headOID?.prefix(7) ?? "HEAD")", detail: repo.repo.name))
            dismiss()
        }
    }
}
