import SwiftUI
import GituniaCore

/// All Changes' right-hand column: one card per changed repository with that repository's own
/// commit draft (the same `CommitComposer` the commit box uses, so drafts carry over both ways),
/// AI generation for several repositories at once, and one Commit / Commit & Push for every
/// checked card. Nothing is checked up front: which repositories get committed is the user's call.
struct WorkspaceCommitPanel: View {
    var workspace: WorkspaceStore
    /// The changed repositories in scope (the sheet's tag filter applies), in display order.
    var repos: [RepositoryStore]
    @Bindable var model: WorkspaceReviewModel
    @Environment(ToastCenter.self) private var toasts

    /// How many messages are generated at the same time — each one is a CLI process or a model call.
    static let generationConcurrency = 3

    private var provider: any CommitMessageProvider { AIProviderFactory.make(workspace.config.settings) }

    private func composer(_ repo: RepositoryStore) -> CommitComposer { CommitComposer.for(repo, in: workspace) }

    /// Mid-merge/rebase repositories, and ones still holding conflicts (a conflicted `stash pop`
    /// has no operation in progress), can't take a normal commit: shown, but not offered.
    static func canCommit(_ repo: RepositoryStore) -> Bool {
        !repo.needsAttention && repo.repo.hasChanges && repo.repo.isAvailable
    }

    private var selected: [RepositoryStore] {
        repos.filter { model.selected.contains($0.id) && Self.canCommit($0) }
    }

    /// Checked repositories whose title is still empty — committing would skip them.
    private var missingMessage: [RepositoryStore] {
        selected.filter { composer($0).title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var isGeneratingAny: Bool { repos.contains { composer($0).isGenerating } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(repos) { repo in
                        CommitCard(
                            repo: repo, composer: composer(repo), provider: provider,
                            isSelected: Binding(
                                get: { model.selected.contains(repo.id) },
                                set: { on in
                                    if on { model.selected.insert(repo.id) } else { model.selected.remove(repo.id) }
                                }
                            ),
                            disabled: model.isCommitting,
                            // Only matters when nothing is staged: the commit then takes every
                            // change, including the ones the review's filters are hiding.
                            hiddenByFilters: repo.stagedChanges.isEmpty
                                ? model.filter.apply(WorkspaceChangesSheet.reviewOrder(repo)).hidden : 0
                        )
                    }
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .confirmationDialog(
            "Review staged changes before committing",
            isPresented: Binding(get: { model.pendingGate != nil }, set: { if !$0 { model.pendingGate = nil } }),
            titleVisibility: .visible
        ) {
            if let gate = model.pendingGate {
                let committable = gate.reports.filter { !$0.report.blocked }
                let clean = gate.reports.filter { $0.report.findings.isEmpty }
                if !committable.isEmpty {
                    Button("Commit \(committable.count) Anyway", role: .destructive) {
                        model.pendingGate = nil
                        finish(committable.map(\.repo), skipped: gate.skipped + Self.blockedNotes(gate), push: gate.push)
                    }
                }
                if !clean.isEmpty && clean.count < committable.count {
                    Button("Commit Only the \(clean.count) Without Findings") {
                        model.pendingGate = nil
                        let flagged = gate.reports.filter { !$0.report.findings.isEmpty }.map { "\($0.repo.repo.name): skipped, review it in the main window" }
                        finish(clean.map(\.repo), skipped: gate.skipped + flagged, push: gate.push)
                    }
                }
            }
            Button("Cancel", role: .cancel) { model.pendingGate = nil }
        } message: {
            Text(model.pendingGate.map(Self.findingsText) ?? "")
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 8) {
            Text("Commit").font(.headline)
            Spacer()
            let selectable = repos.filter(Self.canCommit)
            Button(model.selected.isSuperset(of: selectable.map(\.id)) && !selectable.isEmpty ? "Select None" : "Select All") {
                if model.selected.isSuperset(of: selectable.map(\.id)) {
                    model.selected.subtract(selectable.map(\.id))
                } else {
                    model.selected.formUnion(selectable.map(\.id))
                }
            }
            .controlSize(.small)
            .disabled(selectable.isEmpty || model.isCommitting)
            if isGeneratingAny {
                Button("Stop") { stopGenerating() }
                    .controlSize(.small)
            } else {
                Button { generateSelected() } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(selected.isEmpty || model.isCommitting)
                .help("Generate a commit message with \(provider.name) for every checked repository that has none yet (\(Self.generationConcurrency) at a time)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = model.commitProgress {
                HStack { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(.secondary) }
            } else if !missingMessage.isEmpty {
                Text("No message yet: \(missingMessage.map(\.repo.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                let count = selected.count
                Button("Commit \(count)") { commitSelected(push: false) }
                    .disabled(count == 0 || !missingMessage.isEmpty || model.isCommitting || isGeneratingAny)
                Button("Commit & Push \(count)") { commitSelected(push: true) }
                    .disabled(count == 0 || !missingMessage.isEmpty || model.isCommitting || isGeneratingAny)
                    .help("Commit, then push every repository that already has an upstream")
                Spacer()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
        }
        .padding(10)
    }

    // MARK: - Generating

    /// Generates for every checked repository without a title, `generationConcurrency` at a time,
    /// through the same pipeline as the commit box (Local AI only, secret warning, trailer strip).
    private func generateSelected() {
        let provider = provider
        let composers = selected.map { composer($0) }.filter { !$0.isGenerating && $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !composers.isEmpty else { return }
        model.generateAllTask?.cancel()
        model.generateAllTask = Task {
            for start in stride(from: 0, to: composers.count, by: Self.generationConcurrency) {
                if Task.isCancelled { break }
                let chunk = composers[start..<min(start + Self.generationConcurrency, composers.count)]
                let tasks = chunk.map { composer in
                    let task = Task { await composer.generate(with: provider) }
                    composer.generateTask = task
                    return task
                }
                for task in tasks { await task.value }
            }
        }
    }

    private func stopGenerating() {
        model.generateAllTask?.cancel()
        for repo in repos { composer(repo).generateTask?.cancel() }
    }

    // MARK: - Committing

    /// Stage-if-empty and scan every checked repository first; any finding stops for one
    /// confirmation listing them all, otherwise everything is committed straight away.
    private func commitSelected(push: Bool) {
        let targets = selected
        guard !targets.isEmpty, missingMessage.isEmpty else { return }
        model.isCommitting = true
        Task {
            var reports: [WorkspaceReviewModel.PendingGate.Entry] = []
            var skipped: [String] = []
            for (index, repo) in targets.enumerated() {
                model.commitProgress = "Checking \(repo.repo.name) (\(index + 1) of \(targets.count))…"
                guard await CommitGate.stageIfNothingStaged(repo) else {
                    skipped.append("\(repo.repo.name): nothing to commit")
                    continue
                }
                reports.append(.init(repo: repo, report: await CommitGate.scan(repo, amending: false)))
            }
            model.commitProgress = nil
            if reports.contains(where: { !$0.report.findings.isEmpty }) {
                model.isCommitting = false
                model.pendingGate = .init(reports: reports, skipped: skipped, push: push)
                return
            }
            finish(reports.map(\.repo), skipped: skipped, push: push)
        }
    }

    /// Commits each repository with its own draft, then (for "& Push") pushes the ones that
    /// committed. A bulk push never creates a remote branch: repositories without an upstream are
    /// left for a deliberate single push, as are ones whose earlier unpushed commits look like
    /// they hold a secret (the single push shows what it found).
    private func finish(_ repos: [RepositoryStore], skipped: [String], push: Bool) {
        model.isCommitting = true
        Task {
            defer { model.isCommitting = false; model.commitProgress = nil }
            var committed: [RepositoryStore] = []
            var notes = skipped
            let strip = workspace.config.settings.stripAgentTrailers
            for (index, repo) in repos.enumerated() {
                model.commitProgress = "Committing \(repo.repo.name) (\(index + 1) of \(repos.count))…"
                let draft = composer(repo)
                var message = CommitMessage(title: draft.title.trimmingCharacters(in: .whitespaces), body: draft.body)
                if strip { message = TrailerStripper.strip(message) }
                if await repo.commit(message) {
                    committed.append(repo)
                    draft.title = ""; draft.body = ""
                    model.selected.remove(repo.id)
                } else {
                    let why = repo.lastError?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    notes.append("\(repo.repo.name): commit failed\(why.map { " — \($0)" } ?? "")")
                }
            }
            var pushed = 0
            if push {
                for (index, repo) in committed.enumerated() {
                    model.commitProgress = "Pushing \(repo.repo.name) (\(index + 1) of \(committed.count))…"
                    guard repo.hasUpstream && repo.upstreamMatchesBranch else {
                        notes.append("\(repo.repo.name): not pushed, no upstream yet — push it on its own")
                        continue
                    }
                    if !(await repo.unpushedSecretFindings()).isEmpty {
                        notes.append("\(repo.repo.name): not pushed, unpushed commits look like they contain a secret — push it on its own to review")
                        continue
                    }
                    let result = await repo.push()
                    if result.succeeded {
                        pushed += 1
                    } else {
                        let why = result.error?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        notes.append("\(repo.repo.name): push failed — \((why?.isEmpty == false ? why : nil) ?? result.summary)")
                    }
                }
            }
            let title = "Committed \(committed.count) of \(repos.count + skipped.count)" + (push ? ", pushed \(pushed)" : "")
            if notes.isEmpty {
                toasts.post(.success(title))
            } else {
                let detail = notes.joined(separator: "\n")
                toasts.post(.error(title, detail: detail, stderr: detail))
            }
        }
    }

    private static func blockedNotes(_ gate: WorkspaceReviewModel.PendingGate) -> [String] {
        gate.reports.filter(\.report.blocked).map { "\($0.repo.repo.name): no git identity — set user.name and user.email" }
    }

    private static func findingsText(_ gate: WorkspaceReviewModel.PendingGate) -> String {
        gate.reports.filter { !$0.report.findings.isEmpty }.map { entry in
            "\(entry.repo.repo.name)\(entry.report.blocked ? " (can't commit)" : ""):\n"
                + entry.report.findings.map { "  \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// One repository's draft in the commit column.
private struct CommitCard: View {
    let repo: RepositoryStore
    @Bindable var composer: CommitComposer
    let provider: any CommitMessageProvider
    @Binding var isSelected: Bool
    let disabled: Bool
    var hiddenByFilters = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!WorkspaceCommitPanel.canCommit(repo) || disabled)
                Text(repo.repo.name).font(.headline).lineLimit(1)
                if let branch = repo.repo.branch {
                    Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if repo.repo.localAIOnly {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Local AI only")
                }
                generateControl
            }
            if let operation = repo.operation {
                Text(operation.commitBoxMessage).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(stagingSummary).font(.caption).foregroundStyle(.secondary)
                if hiddenByFilters > 0 {
                    Label("Includes \(hiddenByFilters) file\(hiddenByFilters == 1 ? "" : "s") hidden by the filters",
                          systemImage: "eye.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Nothing is staged, so the commit stages every change — not only the files shown on the left. Stage the ones you want to limit it.")
                }
                TextField("Commit title (feat: …)", text: $composer.title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
                TextField("Description (optional)", text: $composer.body, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.callout)
                    .disabled(disabled)
            }
            if let error = composer.generateError {
                Text(error).font(.caption).foregroundStyle(Theme.status(.deleted)).textSelection(.enabled)
            }
            if let pending = composer.pendingSecretWarning {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looks like it contains \(pending.labels.joined(separator: ", ")). Send it to \(pending.provider.name) anyway?")
                        .font(.caption)
                    if !pending.files.isEmpty {
                        Text(pending.files.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Send Anyway", role: .destructive) { composer.confirmSecretWarning() }
                        Button("Cancel") { composer.pendingSecretWarning = nil }
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(Theme.status(.conflicted).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(isSelected ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.brand : Color.clear, lineWidth: 1))
    }

    /// What the commit will take: what's staged, or — when nothing is — everything (as the commit box does).
    private var stagingSummary: String {
        let staged = repo.stagedChanges.count
        let total = repo.repo.changeCount
        if staged == 0 { return "\(total) changed file\(total == 1 ? "" : "s"), all staged on commit" }
        return "\(staged) staged of \(total) changed file\(total == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var generateControl: some View {
        if composer.isGenerating {
            ProgressView().controlSize(.small)
            Button { composer.generateTask?.cancel() } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Stop generating")
        } else {
            let blocked = repo.repo.localAIOnly && !provider.isLocal
            Button { composer.start(with: provider) } label: { Image(systemName: "sparkles") }
                .buttonStyle(.borderless)
                .disabled(blocked || disabled || repo.operation != nil)
                .help(blocked ? "This repo is Local AI only. Select Ollama in Settings."
                      : repo.stagedChanges.isEmpty ? "Stage all changes, then generate a message with \(provider.name)"
                      : "Generate a message from the staged changes with \(provider.name)")
        }
    }
}
