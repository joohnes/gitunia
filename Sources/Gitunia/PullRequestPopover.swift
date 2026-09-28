import SwiftUI
import AppKit
import GituniaCore

extension PullRequest.Check.Outcome {
    var color: Color {
        switch self {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .yellow
        case .neutral: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .neutral: return "minus.circle.fill"
        }
    }
}

/// Toolbar item: hidden unless `gh` is installed and origin is GitHub. Shows `#N` plus a checks
/// dot when the current branch has a PR; click opens `PullRequestPopover`.
struct PullRequestToolbarButton: View {
    let repo: RepositoryStore
    @State private var showPopover = false

    var body: some View {
        if repo.pullRequestsSupported {
            let pr = repo.currentPullRequest
            Button { showPopover.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.pull")
                    if let pr { Text("#\(pr.number)").monospacedDigit() }
                    if let outcome = pr?.checksOutcome {
                        Circle().fill(outcome.color).frame(width: 7, height: 7)
                    }
                }
            }
            .help(pr.map { "Pull request #\($0.number): \($0.title)" } ?? "Create Pull Request…")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) { PullRequestPopover(repo: repo) }
        }
    }
}

/// The current branch's PR (details) or, when there is none, the create form. Also used as a
/// sheet from the ⌘K palette.
struct PullRequestPopover: View {
    let repo: RepositoryStore
    @State private var loaded = false

    var body: some View {
        Group {
            if let pr = repo.currentPullRequest {
                PullRequestDetails(pr: pr) { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } }
            } else if loaded {
                CreatePullRequestForm(repo: repo)
            } else {
                ProgressView().controlSize(.small).padding(24)
            }
        }
        .frame(width: 380)
        .task {
            await repo.refreshPullRequest()
            loaded = true
        }
    }
}

/// The palette's "Create Pull Request…": the same popover content as a sheet (no toolbar anchor there).
struct PullRequestSheet: ViewModifier {
    @Binding var target: RepositoryStore?
    var onFinish: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $target, onDismiss: onFinish) { store in
            PullRequestPopover(repo: store)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { target = nil } }
                }
        }
    }
}

struct PullRequestDetails: View {
    let pr: PullRequest
    var onOpen: () -> Void

    private var stateLabel: (String, Color) {
        if pr.isDraft && pr.state == "OPEN" { return ("Draft", .secondary) }
        switch pr.state {
        case "OPEN": return ("Open", .green)
        case "MERGED": return ("Merged", .purple)
        default: return ("Closed", .red)
        }
    }

    private var review: (String, String, Color)? {
        switch pr.reviewDecision {
        case "APPROVED": return ("Approved", "checkmark.seal.fill", .green)
        case "CHANGES_REQUESTED": return ("Changes requested", "exclamationmark.bubble.fill", .red)
        case "REVIEW_REQUIRED": return ("Review required", "eye", .secondary)
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(stateLabel.0)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(stateLabel.1.opacity(0.18), in: Capsule())
                    .foregroundStyle(stateLabel.1)
                Text("#\(pr.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let review {
                    Label(review.0, systemImage: review.1).font(.caption).foregroundStyle(review.2)
                }
            }
            Text(pr.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text("\(pr.headRefName) → \(pr.baseRefName)").font(.caption.monospaced()).foregroundStyle(.secondary)

            if let checks = pr.statusCheckRollup, !checks.isEmpty {
                Divider()
                Text("Checks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        HStack(spacing: 6) {
                            Image(systemName: check.outcome.symbol).foregroundStyle(check.outcome.color)
                            Text(check.displayName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(check.result.lowercased().replacingOccurrences(of: "_", with: " "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Open in Browser", systemImage: "safari", action: onOpen)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

struct CreatePullRequestForm: View {
    let repo: RepositoryStore
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = ""
    @State private var draft = false
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create Pull Request").font(.headline)
            Text("\(repo.repo.branch ?? "HEAD") → \(base.isEmpty ? "default branch" : base)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            TextField("Title", text: $title)
            TextEditor(text: $bodyText)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                TextField("Base", text: $base).frame(width: 140)
                Toggle("Draft", isOn: $draft)
                Spacer()
            }
            if let error = error ?? repo.lastGHError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !repo.hasUpstream { Text("Push the branch first.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                Button("Create Pull Request") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .task {
            let raw = await repo.defaultBaseBranch()
            base = raw.map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 } ?? ""
            let prefill = await repo.pullRequestDraft(base: raw)
            if title.isEmpty { title = prefill.title }
            if bodyText.isEmpty { bodyText = prefill.body }
        }
    }

    private func create() {
        creating = true
        error = nil
        Task {
            let result = await repo.createPullRequest(title: title, body: bodyText, draft: draft, base: base)
            creating = false
            switch result {
            case .success(let pr): toasts?.post(.success("Opened pull request #\(pr.number)", detail: repo.repo.name))
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}
