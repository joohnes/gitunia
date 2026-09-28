import SwiftUI
import AppKit
import GituniaCore

/// Posts the Activity report to GitHub via `gh` — as a comment on an open PR or as a new issue.
/// Outward-facing: the Post button always goes through a confirmation naming the repo and target.
struct PostReportSheet: View {
    enum Target: String, CaseIterable, Identifiable {
        case comment = "PR comment", issue = "New issue"
        var id: String { rawValue }
    }

    let store: RepositoryStore
    /// `owner/repo`, for the confirmation text.
    let slug: String
    var toasts: ToastCenter?
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var target: Target = .comment
    /// nil while loading (on appear); render tests inject a list.
    @State private var pullRequests: [PullRequest]?
    @State private var prNumber: Int?
    @State private var title: String
    @State private var labels = "agent-activity"
    @State private var confirming = false
    @State private var posting = false
    @State private var error: String?

    init(store: RepositoryStore, slug: String, report: String, rangeLabel: String, toasts: ToastCenter?,
         pullRequests: [PullRequest]? = nil) {
        self.store = store
        self.slug = slug
        self.toasts = toasts
        _text = State(initialValue: report)
        _title = State(initialValue: "Agent activity \(rangeLabel)")
        _pullRequests = State(initialValue: pullRequests)
        _prNumber = State(initialValue: pullRequests?.first?.number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Post Report to \(slug)").font(.headline)
            Picker("As", selection: $target) {
                ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Form {
                switch target {
                case .comment:
                    if let prs = pullRequests, !prs.isEmpty {
                        Picker("Pull request", selection: $prNumber) {
                            ForEach(prs, id: \.number) { Text("#\($0.number) · \($0.title) (\($0.headRefName))").tag(Optional($0.number)) }
                        }
                    } else {
                        TextField("PR number", value: $prNumber, format: .number.grouping(.never))
                        if pullRequests == nil { ProgressView().controlSize(.small) }
                    }
                case .issue:
                    TextField("Title", text: $title)
                    TextField("Labels (comma-separated)", text: $labels)
                }
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
            }
            HStack {
                if posting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Post…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPost)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
        .task {
            guard pullRequests == nil else { return }
            let prs = await store.openPullRequests()
            pullRequests = prs
            if prNumber == nil { prNumber = prs.first?.number }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Post") { post() }
        } message: {
            Text("It will be visible to everyone with access to the repository.")
        }
    }

    private var canPost: Bool {
        guard !posting, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch target {
        case .comment: return (prNumber ?? 0) > 0
        case .issue: return !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var confirmTitle: String {
        let what = target == .comment ? "a PR comment on #\(prNumber ?? 0)" : "a new issue"
        return "Post this report to \(slug) as \(what)?"
    }

    private func post() {
        posting = true
        error = nil
        Task {
            let result: Result<URL, GHError>
            switch target {
            case .comment:
                result = await store.postPullRequestComment(number: prNumber ?? 0, body: text)
            case .issue:
                let list = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                result = await store.createIssue(title: title, body: text, labels: list)
            }
            posting = false
            switch result {
            case .success(let url):
                toasts?.post(Toast(style: .success, title: target == .comment ? "Comment posted" : "Issue created",
                                   detail: url.absoluteString,
                                   action: ToastAction(title: "Open") { Task { @MainActor in NSWorkspace.shared.open(url) } }))
                dismiss()
            case .failure(let e):
                error = RepoURL.redactingCredentials(e.errorDescription ?? "\(e)")
            }
        }
    }
}
