import SwiftUI
import GituniaCore

/// Shared by the History bar and ⌘K. Failures land in `lastError` (toasted by `ContentView`).
@MainActor
enum BisectRunner {
    /// `hash`, when given, marks a commit other than the one under test — History's context menu
    /// offers "Bisect: Mark Good/Bad" on any commit while bisecting (B7c), not only the current one.
    static func mark(_ verdict: BisectVerdict, hash: String? = nil, on store: RepositoryStore, toasts: ToastCenter) async {
        guard await store.bisectMark(verdict, hash: hash) == nil, let bad = store.bisect?.firstBad else { return }
        toasts.post(.success("First bad commit: \(bad.prefix(7))", detail: store.repo.name))
    }

    static func reset(_ store: RepositoryStore, toasts: ToastCenter) async {
        guard await store.bisectReset() == nil else { return }
        toasts.post(.success("Bisect reset", detail: store.repo.name))
    }
}

/// The bar at the top of History while `repo.bisect` is set: the commit under test with
/// Good/Bad/Skip/Reset, or — once git names it — the first bad commit with Show/Reset.
struct BisectPanel: View {
    var repo: RepositoryStore
    let state: BisectState
    var onShow: (String) -> Void = { _ in }
    @Environment(ToastCenter.self) private var toasts
    @State private var subject: String?

    private var hash: String? { state.firstBad ?? state.current }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.firstBad == nil ? "scope" : "flag.fill")
                .foregroundStyle(state.firstBad == nil ? Theme.brand : .red)
            Group {
                if state.firstBad != nil {
                    Text("First bad commit: ").fontWeight(.semibold) + commitText
                } else {
                    Text(stepsText).fontWeight(.semibold) + Text(" · testing ") + commitText
                }
            }
            .font(.subheadline)
            .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if let bad = state.firstBad {
                Button("Show") { onShow(bad) }.buttonStyle(.borderedProminent)
            } else {
                Button("Good") { mark(.good) }.help("git bisect good")
                Button("Bad") { mark(.bad) }.help("git bisect bad")
                Button("Skip") { mark(.skip) }.help("git bisect skip — this commit can't be tested")
            }
            Button("Reset") { Task { await BisectRunner.reset(repo, toasts: toasts) } }
                .help("git bisect reset — back to where you started")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(repo.isBusy)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.brand.opacity(0.12))
        .task(id: hash) {
            subject = nil
            if let hash { subject = await repo.commitInfo(hash)?.subject }
        }
    }

    private var stepsText: String {
        guard let steps = state.remainingSteps else { return "Bisecting" }
        return "Bisecting — \(steps) step\(steps == 1 ? "" : "s") left"
    }

    private var commitText: Text {
        let short = Text(hash.map { String($0.prefix(7)) } ?? "—").font(.subheadline.monospaced())
        guard let subject else { return short }
        return short + Text(" “\(subject)”").foregroundStyle(.secondary)
    }

    private func mark(_ verdict: BisectVerdict) {
        Task { await BisectRunner.mark(verdict, on: repo, toasts: toasts) }
    }
}

/// Colored leading mark on a History row that bisect has classified (or is testing).
struct BisectRowMark: View {
    let state: BisectState?
    let hash: String

    var body: some View {
        if let state, let m = mark(state) {
            Label(m.text, systemImage: "circle.fill")
                .labelStyle(BisectMarkLabelStyle(color: m.color))
        }
    }

    private func mark(_ state: BisectState) -> (text: String, color: Color)? {
        if hash == state.firstBad { return ("first bad", .red) }
        if hash == state.current { return ("testing", Theme.brand) }
        switch state.verdict(for: hash) {
        case .good: return ("good", .green)
        case .bad: return ("bad", .red)
        case .skip: return ("skipped", .secondary)
        case nil: return nil
        }
    }
}

private struct BisectMarkLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 5))
            configuration.title.font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

/// "Start Bisect": Bad defaults to HEAD, Good to the commit History's menu was opened on.
struct BisectStartSheet: View {
    var repo: RepositoryStore
    @State var good: String
    @State var bad = "HEAD"
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    init(repo: RepositoryStore, good: String = "") {
        self.repo = repo
        self._good = State(initialValue: good)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start Bisect").font(.headline)
            Text("Git checks out commits between them; test each and mark it. Your working tree must be clean.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Bad", text: $bad, prompt: Text("HEAD"))
                TextField("Good", text: $good, prompt: Text("hash, tag or branch"))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed(bad).isEmpty || trimmed(good).isEmpty || repo.isBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func start() async {
        if let e = await repo.bisectStart(bad: trimmed(bad), good: trimmed(good)) {
            error = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            repo.lastError = nil // shown inline; don't also toast it
            return
        }
        toasts.post(.success("Bisect started", detail: repo.repo.name))
        dismiss()
    }
}
