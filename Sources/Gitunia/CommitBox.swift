import SwiftUI
import GituniaCore

struct CommitBox: View {
    var workspace: WorkspaceStore
    var repo: RepositoryStore
    /// Render tests only: switch Amend on at appear — the offscreen harness can't click the checkbox.
    var amendOnAppear = false
    @Environment(ToastCenter.self) private var toasts
    // Optional: render tests host the box without it (same convention as `RepoSheets`).
    @Environment(RemoteOpsCoordinator.self) private var remoteOps: RemoteOpsCoordinator?
    @Environment(RepoSheets.self) private var repoSheets: RepoSheets?
    /// The remote's default branch, without `origin/` — no PR is offered from it.
    @State private var defaultBranch: String?
    @State private var isCommitting = false
    @State private var isAmending = false
    /// The amend fields: a reword of the *last* commit, not a draft for the next one, so they live
    /// here rather than in the per-repo composer — the draft is simply shown again when amend ends.
    /// Which repo `isAmending` is about — a generation finishing after a switch must not fill
    /// another repo's amend fields.
    @State private var amendingRepo: URL?
    @State private var amendTitle = ""
    @State private var amendBody = ""
    @State private var amendFetchTask: Task<Void, Never>?
    /// The commit being amended as the user saw it; `commit(amend:)` refuses if HEAD moved off it.
    @State private var amendHead: String?
    @State private var pendingAmendWarning: PreflightIssue?
    /// Set when the staged diff about to be committed has secret-shaped added lines — an agent may
    /// have staged a key the human never looked at — or staged files over the large-file threshold.
    /// One line per finding; secrets carry only path + label, never the matched value.
    @State private var pendingCommitFindings: [String] = []
    /// A finding in `pendingCommitFindings` is a blocker (no git identity) — only Cancel is offered.
    @State private var commitBlocked = false
    /// First large-file finding's `git lfs track` pattern and path, set only when `git lfs` is installed.
    @State private var lfsSuggestion: (pattern: String, path: String)?
    /// HEAD's body before amend-seeding stripped agent trailers from it — backs the "Undo" note.
    @State private var unstrippedAmendBody: String?
    /// The user pressed that Undo — commit this amend with its trailers intact.
    @State private var keepTrailers = false

    /// This repo's draft and generation state. Per repo, not `@State`: the box is reused across repo
    /// switches, and a generation started in one repo must land there, not in whichever is shown.
    private var composer: CommitComposer { CommitComposer.for(repo, in: workspace) }
    private var title: String { isAmending ? amendTitle : composer.title }
    private var body_: String { isAmending ? amendBody : composer.body }
    private var titleBinding: Binding<String> { isAmending ? $amendTitle : Bindable(composer).title }
    private var bodyBinding: Binding<String> { isAmending ? $amendBody : Bindable(composer).body }

    private var canCommit: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !repo.isBusy, !isCommitting, repo.operation == nil else { return false }
        return isAmending || repo.repo.hasChanges
    }

    /// Clean tree with unpushed commits: "and Push" pushes on its own.
    private var pushOnly: Bool { !repo.isBusy && !repo.repo.hasChanges && repo.repo.ahead > 0 }
    /// Clean, fully pushed feature branch with no open PR (a merged/closed one doesn't count): the
    /// "and Push" slot offers the PR instead.
    private var offersPullRequest: Bool {
        guard repoSheets != nil, !isAmending, !repo.isBusy, !repo.repo.hasChanges, repo.repo.ahead == 0,
              repo.hasUpstream, repo.pullRequestsSupported, repo.currentPullRequest?.state != "OPEN",
              let branch = repo.repo.branch else { return false }
        return branch != defaultBranch
    }
    /// Set by "and Push"; `performCommit` pushes after a successful commit. Reset by every `commit(thenPush:)`.
    @State private var pushAfterCommit = false

    @FocusState private var focusedField: Field?
    private enum Field { case title, body }

    var body: some View {
        if let operation = repo.operation {
            // T2: a normal commit or amend during merge/rebase/cherry-pick/revert is meaningless
            // (there's a specific "finish this operation" action for that — the banner in
            // ChangesView) and was a known defect in T1 (the box stayed usable during a rebase).
            // Hidden entirely rather than shown-disabled: there is nothing here worth a disabled
            // text field and button when the actual action lives one view up.
            Text(operation.commitBoxMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            commitForm
        }
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Amend last commit", isOn: Binding(get: { isAmending }, set: { setAmending($0) }))
                .disabled(repo.isBusy || isCommitting)
                .font(.caption)
            // Both fields share one look: same rounded frame, brand stroke on the focused one.
            TextField("", text: titleBinding)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .focused($focusedField, equals: .title)
                .modifier(CommitFieldFrame(focused: focusedField == .title))
                .overlay(alignment: .leading) {
                    // Same placeholder treatment as the description below (a plain prompt
                    // renders in the primary color on macOS).
                    if title.isEmpty {
                        Text(isAmending ? "Commit title" : "Commit title (feat: …)").foregroundStyle(.tertiary).padding(.horizontal, 6)
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit { commit() }
            TextEditor(text: bodyBinding)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .focused($focusedField, equals: .body)
                .modifier(CommitFieldFrame(focused: focusedField == .body))
                .overlay(alignment: .topLeading) {
                    if body_.isEmpty {
                        Text("Description (optional)").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            if let original = unstrippedAmendBody {
                let n = TrailerStripper.findings(in: original).count
                HStack(spacing: 4) {
                    Text("Removed \(n) agent trailer\(n == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Undo") { amendBody = original; unstrippedAmendBody = nil; keepTrailers = true }.buttonStyle(.link)
                }
                .font(.caption)
            }
            if let id = repo.identity, let name = id.name, let email = id.email {
                HStack(spacing: 4) {
                    if id.signingEnabled { Image(systemName: "signature").help("Commits are signed") }
                    Text("Committing as \(name) <\(email)>").lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                generateButton
                Spacer()
                // Joined pair: Commit, and Commit-then-Push (just Push on a clean tree with unpushed commits).
                HStack(spacing: 1) {
                    Button(isAmending ? "Amend" : "Commit") { commit() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCommit)
                    if offersPullRequest {
                        Button("Create PR…") { repoSheets?.active = .pullRequest(repo) }
                            .keyboardShortcut(.return, modifiers: [.command, .shift])
                            .help("Open a pull request for \(repo.repo.branch ?? "this branch")")
                    } else if remoteOps != nil && !isAmending {
                        Button("and Push") {
                            if canCommit { commit(thenPush: true) } else { Task { await remoteOps?.requestPush(on: repo, toasts: toasts) } }
                        }
                            .keyboardShortcut(.return, modifiers: [.command, .shift])
                            .disabled(!canCommit && !pushOnly)
                            .help(canCommit ? "Commit, then push" : "Push \(repo.repo.ahead) unpushed commit\(repo.repo.ahead == 1 ? "" : "s")")
                    }
                }
                .buttonStyle(SegmentButtonStyle())
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let generateError = composer.generateError {
                HStack {
                    Text(generateError).font(.caption).foregroundStyle(Theme.status(.deleted)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generateError, forType: .string)
                    }
                    .font(.caption)
                }
            }
        }
        .onAppear { if amendOnAppear { setAmending(true) } }
        .task(id: "\(repo.id.path)|\(repo.repo.branch ?? "")") {
            defaultBranch = await repo.defaultBaseBranch().map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
        }
        // `pullRequest` isn't refreshed on checkout — re-read it so a branch that has one doesn't offer "Create PR".
        // Same repo only: selecting a repo already refreshes it (`ContentView`), a second call would race it.
        .onChange(of: [repo.id.path, repo.repo.branch ?? ""]) { old, new in
            if old[0] == new[0], repo.pullRequestsSupported { Task { await repo.refreshPullRequest() } }
        }
        .onChange(of: repo.id) { endAmend() }
        .confirmationDialog(
            "Proceed anyway?",
            isPresented: Binding(get: { pendingAmendWarning != nil }, set: { if !$0 { pendingAmendWarning = nil } }),
            titleVisibility: .visible
        ) {
            Button("Amend Anyway", role: .destructive) {
                pendingAmendWarning = nil
                scanThenCommit()
            }
            Button("Cancel", role: .cancel) { pendingAmendWarning = nil }
        } message: {
            Text(pendingAmendWarning?.message ?? "")
        }
        .confirmationDialog(
            "Send this diff to a cloud AI provider?",
            isPresented: Binding(get: { composer.pendingSecretWarning != nil }, set: { if !$0 { composer.pendingSecretWarning = nil } }),
            titleVisibility: .visible
        ) {
            Button("Send Anyway", role: .destructive) {
                composer.confirmSecretWarning(deliver: deliver(to: repo.url))
            }
            Button("Cancel", role: .cancel) { composer.pendingSecretWarning = nil }
        } message: {
            let pending = composer.pendingSecretWarning
            let files = pending?.files ?? []
            Text("The staged changes look like they contain \(pending?.labels.joined(separator: ", ") ?? ""). It will be sent to \(pending?.provider.name ?? "the cloud provider") to generate a commit message."
                 + (files.isEmpty ? "" : "\n\n" + files.joined(separator: "\n")))
        }
        .confirmationDialog(
            "Review staged changes before committing",
            isPresented: Binding(get: { !pendingCommitFindings.isEmpty }, set: { if !$0 { pendingCommitFindings = [] } }),
            titleVisibility: .visible
        ) {
            if !commitBlocked {
                Button("Commit Anyway", role: .destructive) {
                    pendingCommitFindings = []
                    performCommit()
                }
            }
            if let lfs = lfsSuggestion {
                Button("Track \(lfs.pattern) with LFS") {
                    pendingCommitFindings = []
                    Task {
                        if let error = await repo.lfsTrack(lfs.pattern) {
                            toasts.post(.error(repo.repo.name, detail: error.stderr))
                            return
                        }
                        // Re-adding the file runs it through the new LFS filter — the index gets a pointer.
                        for path in [".gitattributes", lfs.path] {
                            await repo.stage(FileChange(path: path, status: .modified, area: .unstaged))
                        }
                        scanThenCommit()
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingCommitFindings = [] }
        } message: {
            Text((pendingCommitFindings + (commitBlocked ? ["Open git config… to set user.name and user.email, then commit again."] : []))
                .joined(separator: "\n"))
        }
    }

    /// Amend is a per-glance decision about *this* repo's HEAD, so a repo switch ends it.
    private func endAmend() {
        amendFetchTask?.cancel()
        isAmending = false
        amendingRepo = nil
        unstrippedAmendBody = nil; keepTrailers = false
    }

    private func setAmending(_ on: Bool) {
        guard on != isAmending else { return }
        if on {
            let issues = Preflight.check(.amend, repo: repo.repo, hasUpstream: repo.hasUpstream)
            if let blocker = issues.first(where: { $0.severity == .blocker }) {
                toasts.post(.error(repo.repo.name, detail: blocker.message))
                return
            }
            amendTitle = ""; amendBody = ""
            isAmending = true
            amendingRepo = repo.url
            amendHead = repo.repo.headOID
            amendFetchTask = Task {
                guard let (hash, last) = await repo.lastCommit(), !Task.isCancelled else { return }
                amendHead = hash
                let seeded = stripIfEnabled(last)
                amendTitle = seeded.title
                amendBody = seeded.body
                unstrippedAmendBody = seeded.body == last.body ? nil : last.body
            }
        } else {
            endAmend()
        }
    }

    @ViewBuilder
    private var generateButton: some View {
        let provider = AIProviderFactory.make(workspace.config.settings)
        let blocked = repo.repo.localAIOnly && !provider.isLocal
        if composer.isGenerating {
            Button("Cancel") { composer.generateTask?.cancel() }
            ProgressView().controlSize(.small)
        } else {
            let stagesFirst = repo.stagedChanges.isEmpty
            Button { generate(with: provider) } label: {
                // Full label when there's room, icon-only (tooltip carries the words) when the
                // column is narrow — never a truncated "Stage all & Gen…".
                ViewThatFits(in: .horizontal) {
                    Label(stagesFirst ? "Stage All & Generate" : "Generate", systemImage: "sparkles").fixedSize()
                    Image(systemName: "sparkles")
                }
            }
                .disabled(blocked || repo.repo.changes.isEmpty)
                .help(blocked
                      ? "This repo is Local AI only. Select Ollama in Settings."
                      : stagesFirst
                        ? "Stage all changes, then generate a commit message with \(provider.name)"
                        : "Generate a commit message from staged changes with \(provider.name)")
            if repo.repo.localAIOnly {
                Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Local AI only")
            }
        }
    }

    private func generate(with provider: any CommitMessageProvider) {
        composer.start(with: provider, deliver: deliver(to: repo.url, draftAtStart: CommitMessage(title: composer.title, body: composer.body)))
    }

    /// Where a generated message lands: still amending this same repo → it rewords the commit;
    /// otherwise it's the next commit's draft — unless the user typed into the draft while the
    /// model was still working, which a late reply must not overwrite.
    private func deliver(to url: URL, draftAtStart: CommitMessage) -> @MainActor (CommitMessage) -> Void {
        let composer = composer
        return { message in
            if isAmending && amendingRepo == url {
                amendTitle = message.title; amendBody = message.body
            } else if composer.title == draftAtStart.title && composer.body == draftAtStart.body {
                composer.title = message.title; composer.body = message.body
            }
        }
    }

    private func commit(thenPush: Bool = false) {
        guard canCommit else { return }
        // A reply landing after this commit would refill the cleared draft with a message
        // describing changes that are already committed.
        composer.generateTask?.cancel()
        pushAfterCommit = thenPush && !isAmending
        if isAmending {
            let issues = Preflight.check(.amend, repo: repo.repo, hasUpstream: repo.hasUpstream)
            if let blocker = issues.first(where: { $0.severity == .blocker }) {
                toasts.post(.error(repo.repo.name, detail: blocker.message))
                return
            }
            if let warning = issues.first(where: { $0.severity == .warning }) {
                pendingAmendWarning = warning
                return
            }
        }
        scanThenCommit()
    }

    /// Commit gate: scans the added lines of the staged diff and asks before committing anything
    /// secret-shaped, or any staged file over the large-file threshold — both in one dialog.
    /// Only labels and paths are shown, never the matched value. Identity is re-read first (one
    /// cheap `git config` call) so a fixed or broken config is seen here, not just on selection;
    /// the signing note never opens the dialog on its own — the caption's glyph already shows it.
    private func scanThenCommit() {
        isCommitting = true
        Task {
            if !isAmending {
                guard await CommitGate.stageIfNothingStaged(repo) else { isCommitting = false; return }
            }
            let report = await CommitGate.scan(repo, amending: isAmending)
            lfsSuggestion = report.lfsSuggestion
            commitBlocked = report.blocked
            if report.findings.isEmpty {
                performCommit()
            } else {
                isCommitting = false
                pendingCommitFindings = report.findings
            }
        }
    }

    private func performCommit() {
        isCommitting = true
        let amend = isAmending
        let composer = composer
        Task {
            defer { isCommitting = false }
            let message = CommitMessage(title: title.trimmingCharacters(in: .whitespaces), body: body_)
            let ok = await repo.commit(keepTrailers ? message : stripIfEnabled(message), amend: amend,
                                       expectedHead: amend ? amendHead : nil)
            if ok {
                if amend { endAmend() } else { composer.title = ""; composer.body = "" }
                if pushAfterCommit { await remoteOps?.requestPush(on: repo, toasts: toasts) }
            }
            pushAfterCommit = false
        }
    }

    private func stripIfEnabled(_ message: CommitMessage) -> CommitMessage {
        workspace.config.settings.stripAgentTrailers ? TrailerStripper.strip(message) : message
    }
}

/// One half of the joined Commit / and Push pair: brand fill, square inner edges (the pair's clip rounds the outside).
private struct SegmentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Theme.brand.opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1))
    }
}

/// Shared frame for the commit title and description: rounded stroke, brand-colored while focused.
private struct CommitFieldFrame: ViewModifier {
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.brand : Color.secondary.opacity(0.3), lineWidth: focused ? 1.5 : 1))
    }
}

/// One repo's commit draft and AI-generation state, outliving any one `CommitBox` render so that
/// switching repos neither carries text across nor drops a generation that's still running.
/// Edits are persisted through `WorkspaceStore.setCommitDraft` (debounced to disk there).
@MainActor @Observable
final class CommitComposer {
    var title: String { didSet { persist() } }
    var body: String { didSet { persist() } }
    var isGenerating = false
    var generateError: String?
    @ObservationIgnored var generateTask: Task<Void, Never>?
    /// Set when the staged diff looked secret-shaped and we're waiting on the user to confirm
    /// sending it to a cloud provider anyway.
    var pendingSecretWarning: (labels: [String], files: [String], provider: any CommitMessageProvider, prompt: String)?

    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private weak var repo: RepositoryStore?

    private init(repo: RepositoryStore, workspace: WorkspaceStore) {
        title = repo.restoredDraft?.title ?? ""
        body = repo.restoredDraft?.body ?? ""
        self.repo = repo
        self.workspace = workspace
    }

    private func persist() {
        guard let repo, let workspace else { return }
        workspace.setCommitDraft(CommitMessage(title: title, body: body), for: repo)
    }

    // MARK: - Generating a message

    /// Starts `generate` as this draft's (cancellable) generation, replacing one still running.
    func start(with provider: any CommitMessageProvider, deliver: (@MainActor (CommitMessage) -> Void)? = nil) {
        generateTask?.cancel()
        generateTask = Task { await generate(with: provider, deliver: deliver) }
    }

    /// The commit box's and All Changes' shared pipeline: stage everything when nothing is
    /// staged, build the prompt, stop to ask before a secret-shaped diff goes to a cloud provider
    /// (`pendingSecretWarning`), then generate. `deliver` receives the message; nil = this draft.
    func generate(with provider: any CommitMessageProvider, deliver: (@MainActor (CommitMessage) -> Void)? = nil) async {
        guard let repo, let workspace else { return }
        generateError = nil
        pendingSecretWarning = nil
        isGenerating = true
        if repo.repo.localAIOnly && !provider.isLocal {
            generateError = AIError.localOnlyRepo(providerName: provider.name).localizedDescription
            isGenerating = false
            return
        }
        if repo.stagedChanges.isEmpty { await repo.stageAll() }
        let (stat, diff) = await repo.stagedDiffForAI()
        guard !Task.isCancelled else { isGenerating = false; return }
        guard !diff.isEmpty else { generateError = "Nothing staged to describe."; isGenerating = false; return }
        let prompt = PromptBuilder.build(stat: stat, diff: diff, limit: workspace.config.settings.diffCharLimit)
        // Cloud providers see the raw diff; repos not restricted to Local AI still deserve a
        // heads-up before something secret-shaped leaves the machine. `localAIOnly` repos
        // never reach here with a non-local provider (blocked above).
        if !provider.isLocal {
            // Added lines per file, minus files the user excluded; `scan` still catches a secret
            // only in removed/context lines (no file to show, but it's in the diff being sent).
            let all = await SecretScanner.findingsInBackground(inLog: diff)
            let shown = repo.withoutIgnoredSecrets(all)
            let labels = all.isEmpty ? SecretScanner.scan(diff) : Array(Set(shown.map(\.label))).sorted()
            if !labels.isEmpty {
                isGenerating = false
                pendingSecretWarning = (labels, shown.map { "\($0.path): \($0.label)" }, provider, prompt)
                return
            }
        }
        await send(prompt, to: provider, deliver: deliver)
    }

    /// The user agreed to send the secret-shaped diff anyway.
    func confirmSecretWarning(deliver: (@MainActor (CommitMessage) -> Void)? = nil) {
        guard let pending = pendingSecretWarning else { return }
        pendingSecretWarning = nil
        isGenerating = true
        generateTask = Task { await send(pending.prompt, to: pending.provider, deliver: deliver) }
    }

    private func send(_ prompt: String, to provider: any CommitMessageProvider, deliver: (@MainActor (CommitMessage) -> Void)?) async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            var message = try await provider.generate(prompt: prompt)
            if workspace?.config.settings.stripAgentTrailers == true { message = TrailerStripper.strip(message) }
            guard !Task.isCancelled else { return }
            if let deliver { deliver(message) } else { title = message.title; body = message.body }
        } catch is CancellationError {
        } catch {
            generateError = error.localizedDescription
        }
    }

    // ponytail: never evicted — one small object per (window, repo) ever shown; prune on repo removal if that grows.
    private static var all: [Key: CommitComposer] = [:]

    /// Per workspace window as well as per repo: each window keeps its own draft for a repo in
    /// several workspaces (by URL alone, typing in one window persisted into the other's file).
    private struct Key: Hashable {
        let workspace: ObjectIdentifier
        let url: URL
    }

    /// Keyed by URL (within the window) so a rebuilt `RepositoryStore` for the same repo keeps its
    /// draft and running generation.
    static func `for`(_ repo: RepositoryStore, in workspace: WorkspaceStore) -> CommitComposer {
        let key = Key(workspace: ObjectIdentifier(workspace), url: repo.url)
        // `existing.workspace` nil: that window is gone and its identifier was reused — start fresh.
        if let existing = all[key], existing.workspace === workspace {
            existing.repo = repo
            return existing
        }
        let made = CommitComposer(repo: repo, workspace: workspace)
        all[key] = made
        return made
    }
}
