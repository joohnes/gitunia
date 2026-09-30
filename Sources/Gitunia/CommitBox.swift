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
    @State private var title = ""
    @State private var body_ = ""
    @State private var isGenerating = false
    @State private var generateError: String?
    @State private var generateTask: Task<Void, Never>?
    @State private var isCommitting = false
    @State private var isAmending = false
    /// What the user had typed before switching the amend toggle on, restored when it's switched
    /// back off. Lives here (not in the persisted per-repo draft) because the amend fields aren't
    /// a draft for the *next* commit — they're a reword of the *last* one.
    @State private var draftBeforeAmend: CommitMessage?
    @State private var amendFetchTask: Task<Void, Never>?
    /// The commit being amended as the user saw it; `commit(amend:)` refuses if HEAD moved off it.
    @State private var amendHead: String?
    @State private var pendingAmendWarning: PreflightIssue?
    /// Set when a scan of the staged diff turned up something secret-shaped and we're waiting on
    /// the user to confirm sending it to a cloud provider anyway.
    @State private var pendingSecretWarning: (labels: [String], files: [String], provider: any CommitMessageProvider, prompt: String)?
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

    private var canCommit: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !repo.isBusy, !isCommitting, repo.operation == nil else { return false }
        return isAmending || repo.repo.hasChanges
    }

    /// Clean tree with unpushed commits: "and Push" pushes on its own.
    private var pushOnly: Bool { !repo.isBusy && !repo.repo.hasChanges && repo.repo.ahead > 0 }
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
            TextField("", text: $title)
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
            TextEditor(text: $body_)
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
                    Button("Undo") { body_ = original; unstrippedAmendBody = nil; keepTrailers = true }.buttonStyle(.link)
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
                    if remoteOps != nil && !isAmending {
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
            if let generateError {
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
        .onAppear { seedDraft(); if amendOnAppear { setAmending(true) } }
        .onChange(of: repo.id) { seedDraft() }
        .onChange(of: title) { if !isAmending { workspace.setCommitDraft(CommitMessage(title: title, body: body_), for: repo) } }
        .onChange(of: body_) { if !isAmending { workspace.setCommitDraft(CommitMessage(title: title, body: body_), for: repo) } }
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
            isPresented: Binding(get: { pendingSecretWarning != nil }, set: { if !$0 { pendingSecretWarning = nil } }),
            titleVisibility: .visible
        ) {
            Button("Send Anyway", role: .destructive) {
                if let pending = pendingSecretWarning {
                    pendingSecretWarning = nil
                    isGenerating = true
                    generateTask = Task { await runGenerate(with: pending.provider, prompt: pending.prompt) }
                }
            }
            Button("Cancel", role: .cancel) { pendingSecretWarning = nil }
        } message: {
            let files = pendingSecretWarning?.files ?? []
            Text("The staged changes look like they contain \(pendingSecretWarning?.labels.joined(separator: ", ") ?? ""). It will be sent to \(pendingSecretWarning?.provider.name ?? "the cloud provider") to generate a commit message."
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

    /// Seeds the fields from the repo's restored draft. Called on first appearance and whenever
    /// the underlying repo identity changes (the view itself is reused across repo switches, so
    /// `onChange(of: repo.id)` alone would miss the very first repo — hence also `onAppear`).
    /// Also resets the amend toggle — it's a per-glance decision about *this* repo's HEAD, not
    /// something that should follow you to the next repo you look at.
    private func seedDraft() {
        amendFetchTask?.cancel()
        isAmending = false
        draftBeforeAmend = nil
        unstrippedAmendBody = nil; keepTrailers = false
        let draft = repo.restoredDraft
        title = draft?.title ?? ""
        body_ = draft?.body ?? ""
        generateError = nil
    }

    private func setAmending(_ on: Bool) {
        guard on != isAmending else { return }
        if on {
            let issues = Preflight.check(.amend, repo: repo.repo, hasUpstream: repo.hasUpstream)
            if let blocker = issues.first(where: { $0.severity == .blocker }) {
                toasts.post(.error(repo.repo.name, detail: blocker.message))
                return
            }
            draftBeforeAmend = CommitMessage(title: title, body: body_)
            isAmending = true
            amendHead = repo.repo.headOID
            amendFetchTask = Task {
                guard let (hash, last) = await repo.lastCommit(), !Task.isCancelled else { return }
                amendHead = hash
                let seeded = stripIfEnabled(last)
                title = seeded.title
                body_ = seeded.body
                unstrippedAmendBody = seeded.body == last.body ? nil : last.body
            }
        } else {
            amendFetchTask?.cancel()
            isAmending = false
            unstrippedAmendBody = nil; keepTrailers = false
            title = draftBeforeAmend?.title ?? ""
            body_ = draftBeforeAmend?.body ?? ""
            draftBeforeAmend = nil
        }
    }

    @ViewBuilder
    private var generateButton: some View {
        let provider = AIProviderFactory.make(workspace.config.settings)
        let blocked = repo.repo.localAIOnly && !provider.isLocal
        if isGenerating {
            Button("Cancel") { generateTask?.cancel() }
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
        generateError = nil
        isGenerating = true
        generateTask = Task {
            if repo.repo.localAIOnly && !provider.isLocal {
                generateError = AIError.localOnlyRepo(providerName: provider.name).localizedDescription
                isGenerating = false
                return
            }
            if repo.stagedChanges.isEmpty { await repo.stageAll() }
            let (stat, diff) = await repo.stagedDiffForAI()
            guard !diff.isEmpty else { generateError = "Nothing staged to describe."; isGenerating = false; return }
            let prompt = PromptBuilder.build(stat: stat, diff: diff, limit: workspace.config.settings.diffCharLimit)
            // Cloud providers see the raw diff; repos not restricted to Local AI still deserve a
            // heads-up before something secret-shaped leaves the machine. `localAIOnly` repos
            // never reach here with a non-local provider (blocked above), so this only fires for
            // repos where the user could still choose a cloud provider.
            if !provider.isLocal {
                // Added lines per file, minus files the user excluded; `scan` still catches a secret
                // only in removed/context lines (no file to show, but it's in the diff being sent).
                let all = SecretScanner.findings(inDiff: diff)
                let shown = repo.withoutIgnoredSecrets(all)
                let labels = all.isEmpty ? SecretScanner.scan(diff) : Array(Set(shown.map(\.label))).sorted()
                if !labels.isEmpty {
                    isGenerating = false
                    pendingSecretWarning = (labels, shown.map { "\($0.path): \($0.label)" }, provider, prompt)
                    return
                }
            }
            await runGenerate(with: provider, prompt: prompt)
        }
    }

    /// Sends `prompt` to `provider` and fills in the title/body. Called directly from `generate`,
    /// or after the user confirms sending a secret-shaped diff to a cloud provider.
    private func runGenerate(with provider: any CommitMessageProvider, prompt: String) async {
        defer { isGenerating = false }
        do {
            let message = stripIfEnabled(try await provider.generate(prompt: prompt))
            guard !Task.isCancelled else { return }
            title = message.title
            body_ = message.body
        } catch is CancellationError {
        } catch {
            generateError = error.localizedDescription
        }
    }

    private func commit(thenPush: Bool = false) {
        guard canCommit else { return }
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
            // Nothing staged → stage everything first, so the scan below sees what will be
            // committed. Per-file when conflicts exist: `git add -A` would mark them resolved.
            if !isAmending, repo.stagedChanges.isEmpty {
                if repo.conflictedChanges.isEmpty {
                    await repo.stageAll()
                } else {
                    for change in repo.unstagedChanges + repo.untrackedChanges { await repo.stage(change) }
                }
                guard !repo.stagedChanges.isEmpty else { isCommitting = false; return }
            }
            // Independent git calls — run together, not one after another.
            async let identityRefreshed: Void = repo.refreshIdentity()
            async let stagedDiff = repo.stagedDiff()
            async let headPatch = isAmending ? repo.headPatch() : ""
            async let lfsCheck = repo.checkLFSInstalled()
            await identityRefreshed
            let identityIssues = Preflight.identityWarnings(repo.identity).filter { $0.id != "signing" }
            var secrets = repo.withoutIgnoredSecrets(SecretScanner.findings(inDiff: await stagedDiff))
            // Nothing staged (e.g. amending only the message) skips the diff scan above — HEAD's
            // own patch is scanned too so a secret already in the commit still gets caught.
            for finding in repo.withoutIgnoredSecrets(SecretScanner.findings(inLog: await headPatch)) where !secrets.contains(finding) {
                secrets.append(finding)
            }
            let lfsInstalled = await lfsCheck
            let large = Preflight.largeFileWarnings(in: repo.repo.changes, rules: repo.attributeRules, lfsInstalled: lfsInstalled)
            let findings = identityIssues.map(\.message)
                + secrets.map { "\($0.path): \($0.label)" }
                + large.map(\.message)
            // ponytail: one Track button for the first large file; the rescan surfaces the next one.
            lfsSuggestion = lfsInstalled ? large.first.flatMap { issue in
                issue.suggestedLFSPattern.map { ($0, String(issue.id.dropFirst("large-file:".count))) }
            } : nil
            commitBlocked = identityIssues.contains { $0.severity == .blocker }
            if findings.isEmpty {
                performCommit()
            } else {
                isCommitting = false
                pendingCommitFindings = findings
            }
        }
    }

    private func performCommit() {
        isCommitting = true
        let amend = isAmending
        Task {
            defer { isCommitting = false }
            let message = CommitMessage(title: title.trimmingCharacters(in: .whitespaces), body: body_)
            let ok = await repo.commit(keepTrailers ? message : stripIfEnabled(message), amend: amend,
                                       expectedHead: amend ? amendHead : nil)
            if ok {
                isAmending = false
                draftBeforeAmend = nil
                unstrippedAmendBody = nil; keepTrailers = false
                title = ""; body_ = ""
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
