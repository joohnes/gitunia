import SwiftUI
import GituniaCore

/// Huge enough that `git diff -U<context>` always returns the whole file as one hunk.
private let wholeFileContext = 100_000

struct DiffView: View {
    var repo: RepositoryStore
    var change: FileChange
    /// Shared with `ContentView` and `EditFileView` — see `EditSession`'s doc comment for why the
    /// unsaved-edits guard has to live one level up rather than in this view's own `.onDisappear`.
    var editSession: EditSession
    /// The diff toolbar's clock icon — routes to `ContentView.requestFileHistory` for this file.
    var onRequestFileHistory: (String) -> Void = { _ in }
    /// A gutter click in the Blame view — routes to `ContentView`'s blame-navigation helper, which
    /// switches to History, selects the commit, and preselects this file (see
    /// `ContentView.navigateToBlameCommit`).
    var onNavigateToBlameCommit: (String) -> Void = { _ in }
    /// ⌘K's "Blame" action flips this to request blame turn on for whichever file is already open
    /// — `DiffView`'s own `blame` toggle is local `@State`, so there's no other way for a sibling
    /// (the palette) to reach it. Same one-shot-flag shape as `HistoryView.focusFilterRequested`.
    var activateBlameRequested: Binding<Bool> = .constant(false)
    /// Test-only seam (same pattern as `HistoryView.initialBranch`/`CommandPalette.initialQuery`):
    /// lets the offscreen render harness open straight into the Blame view without simulating a
    /// toolbar click. Production call sites never pass this.
    var initialBlame: Bool = false
    @State private var diff: FileDiff?
    /// Resolved by `previewFile(path:at:)` whenever `isPreviewable` — HEAD's copy (nil for an
    /// untracked/added file) and the working-tree copy (nil for a deleted file). Fed straight to
    /// `FilePreviewView`.
    @State private var previewBefore: URL?
    @State private var previewAfter: URL?
    @State private var conflictSegments: [ConflictSegment]?
    @State private var loading = false
    @State private var reloadToken = 0
    @State private var lastChangeID: String?
    @State private var lastRepoURL: URL?
    @State private var isEditing = false
    @State private var editability: FileEditor.Editability = .notEditable(reason: "Checking…")
    /// Set from a real `lstat`-style check (`FileEditor.isSymlink`) whenever `change`'s working-tree
    /// path is itself a symlink — never from following it. While set, the diff/edit/blame body all
    /// show this instead: a symlink can point anywhere on disk (`~/.ssh/id_rsa`, say), so nothing
    /// here ever sizes or reads through it (see `FileEditor.isSymlink`'s doc comment).
    @State private var symlinkTarget: String?
    // Blame (T3): local, not `@AppStorage` — unlike Wrap/mode, defaulting every file to blame on
    // would be a surprising, expensive-by-default reading mode rather than a display preference.
    // Reset to false whenever the file switches, alongside `isEditing` (see the `.task` below).
    @State private var blame: Bool
    @State private var blameResult: BlameResult?
    @State private var blameLoading = false
    @AppStorage("diffMode") private var mode: DiffMode = .inline
    // Defaults to whole-file: seeing the change in context of the whole file is what most
    // people want most of the time; "Hunks" is the opt-in, terser view.
    @AppStorage("diffScope") private var wholeFile = true
    // Default off: it changes how every line lays out, so it should be an opt-in for the (long
    // minified line / long string literal) case rather than the default reading experience.
    @AppStorage("diffWrap") private var wrap = false

    init(
        repo: RepositoryStore, change: FileChange, editSession: EditSession,
        onRequestFileHistory: @escaping (String) -> Void = { _ in },
        onNavigateToBlameCommit: @escaping (String) -> Void = { _ in },
        activateBlameRequested: Binding<Bool> = .constant(false),
        initialBlame: Bool = false
    ) {
        self.repo = repo
        self.change = change
        self.editSession = editSession
        self.onRequestFileHistory = onRequestFileHistory
        self.onNavigateToBlameCommit = onNavigateToBlameCommit
        self.activateBlameRequested = activateBlameRequested
        self.initialBlame = initialBlame
        self._blame = State(initialValue: initialBlame)
    }

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            Divider()
            diffBody
        }
        .toolbar {
            // None of the diff-shaping controls (hunks/whole-file, inline/split, wrap) apply to
            // the marker-based conflict view — it always shows the whole working-tree file. They
            // don't apply to the Blame view either — it always shows the whole working-tree file
            // annotated per line, not a diff.
            if change.status != .conflicted && !blame {
                ToolbarItem {
                    Picker("Scope", selection: $wholeFile) {
                        Text("Hunks").tag(false)
                        Text("Whole file").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(diffShapingDisabledReason != nil)
                    .help(diffShapingDisabledReason ?? "Show only the changed hunks, or the whole file")
                }
                ToolbarItem {
                    Picker("Diff mode", selection: $mode) {
                        ForEach(DiffMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(diffShapingDisabledReason != nil)
                    .help(diffShapingDisabledReason ?? "Show the diff inline or side by side")
                }
                // A single icon toggle rather than folding Wrap into a "View options" menu: Inline
                // vs. Split and Hunks vs. Whole-file are already one click via their segmented
                // pickers, and a menu would cost every wrap toggle an extra click (open, then pick)
                // for no real space win — a compact icon button is narrower than a labeled segmented
                // control while staying just as fast to hit.
                ToolbarItem {
                    // Was an icon button ("arrow.turn.down.left" — see below for why not
                    // "text.wrap"), which read as just another glyph next to Inline/Split and
                    // Hunks/Whole file's segmented controls with no obvious on/off state.
                    ToolbarToggle(label: "Wrap", isOn: $wrap, help: diffShapingDisabledReason ?? "Wrap long lines")
                        .disabled(diffShapingDisabledReason != nil)
                }
            }
            // Blame and Wrap both apply to the annotated whole-file view, so Wrap stays available
            // there too (only Scope/Diff mode, which are diff-specific, are hidden above).
            if change.status != .conflicted && blame {
                ToolbarItem { WrapToggle(isOn: $wrap) }
            }
            // Not shown for a conflicted file — blame reads the working-tree file, and a conflict
            // marker file isn't a meaningful thing to attribute line-by-line.
            if change.status != .conflicted {
                ToolbarItem {
                    ToolbarToggle(label: "Blame", isOn: blameBinding, help: blameDisabledReason ?? "Annotate each line with the commit that last changed it")
                        .disabled(blameDisabledReason != nil)
                }
            }
            // Always shown, like Edit below — a working-tree file always has a path to follow,
            // whether or not it currently has an uncommitted diff.
            ToolbarItem {
                Button {
                    onRequestFileHistory(change.path)
                } label: {
                    Image(systemName: "clock")
                }
                .help("Show File History")
            }
            // Unlike the diff-shaping controls above, Edit is always shown, even for a conflicted
            // file — disabled with a `.help` explaining why, so it's discoverable rather than
            // silently missing. It never applies in History (`DiffView` isn't used there).
            ToolbarItem {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        editSession.guardNavigation { isEditing = false }
                    } else {
                        isEditing = true
                        blame = false
                    }
                }
                .disabled(!isEditing && !editability.isEditable)
                .help(isEditing ? "Return to the diff (⌘S saves)" : (editability.reason ?? "Edit the working-tree file"))
            }
        }
        // Keyed only on what can actually change this file's diff: the file itself (by id), its
        // current status/area entry in the repo (so an external edit or restage reloads it, but
        // an unrelated file's status change elsewhere in the repo does not), the whole-file
        // toggle, and an explicit reload after a hunk stage/unstage.
        .task(id: "\(currentChange.id)-\(currentChange.status)-\(currentChange.oldPath ?? "")-\(currentChange.size ?? -1)-\(wholeFile)-\(reloadToken)") {
            // Only clear the previously-shown diff when we're actually switching files — not on
            // an in-place reload (hunk staged, scope toggled) — so the view doesn't flash back to
            // a spinner and lose scroll position for a same-file refresh.
            if lastChangeID != change.id || lastRepoURL != repo.url {
                diff = nil
                conflictSegments = nil
                // A genuine switch to a different file (or repo) always drops back to the diff —
                // continuing to show an edit buffer for the file that was just left would either
                // point at the wrong file or silently keep stale UI around. Safe to do
                // unconditionally: `change`/`repo` only reach this point after `EditSession` has
                // already resolved any unsaved edits (see `ContentView`'s guarded bindings), so
                // there's nothing left to lose here.
                isEditing = false
                // Only clobber blame on a *genuine* switch away from a previously-loaded file
                // (`lastChangeID` already set) — not on this view's very first task run, which
                // would otherwise stomp `initialBlame`/`activateBlameRequested` before either ever
                // gets a chance to show anything.
                if lastChangeID != nil {
                    blame = false
                    blameResult = nil
                }
            }
            lastChangeID = change.id
            lastRepoURL = repo.url
            let fileURL = repo.url.appendingPathComponent(change.path)
            // M9: `lstat`-check first — before *any* sizing/reading of the working-tree path — so a
            // symlink (e.g. `notes.txt -> ~/.ssh/id_rsa`) never has its target sized, read for
            // UTF-8 validity, or read for the conflict-marker view below. `destinationOfSymbolicLink`
            // reads the link's own text (the path it points at), never the target's bytes.
            symlinkTarget = FileEditor.isSymlink(at: fileURL)
                ? (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path))
                : nil
            editability = symlinkTarget != nil
                ? .notEditable(reason: "This is a symlink")
                : fileEditability(for: change, in: repo.url)
            if change.status == .conflicted {
                guard symlinkTarget == nil else { conflictSegments = []; return }
                let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                conflictSegments = ConflictParser.parse(text)
                return
            }
            loading = true
            async let diffResult = repo.diff(for: change, context: wholeFile ? wholeFileContext : nil)
            async let beforeResult: URL? = isPreviewable ? repo.previewFile(path: change.path, at: "HEAD") : nil
            async let afterResult: URL? = isPreviewable ? repo.previewFile(path: change.path, at: nil) : nil
            diff = await diffResult
            previewBefore = await beforeResult
            previewAfter = await afterResult
            loading = false
        }
        // Loads (and, via `.task(id:)`'s own cancel-and-restart, cancels) blame independently of
        // the diff — only runs while the toggle is on, and reloads if the file/repo changes while
        // it's on.
        .task(id: "\(blame)-\(change.id)-\(repo.url)") {
            guard blame else { blameResult = nil; return }
            blameLoading = true
            blameResult = await repo.blame(path: change.path)
            blameLoading = false
        }
        .onChange(of: activateBlameRequested.wrappedValue) { _, requested in
            guard requested else { return }
            activateBlameRequested.wrappedValue = false
            guard blameDisabledReason == nil else { return }
            blame = true
            isEditing = false
        }
    }

    private var blameBinding: Binding<Bool> {
        Binding(get: { blame }, set: { newValue in
            blame = newValue
            if newValue { isEditing = false }
        })
    }

    /// Why Blame can't be turned on right now, per the plan: never for an untracked file (it has
    /// no history), a conflicted file (excluded above already), a symlink, or a binary file. Also
    /// excluded: a deleted-in-the-working-tree file, since `git blame` needs a working-tree copy to
    /// read.
    ///
    /// L2: binary-ness comes from `diff`, which is `nil` until the diff `.task` finishes loading —
    /// so `diff == nil` (still loading, or not yet started) is itself treated as "don't know yet,
    /// disable" rather than falling through to "no reason found, enable". Without this there's a
    /// window right after opening a binary file where Blame is enabled and clickable before `diff`
    /// populates.
    private var blameDisabledReason: String? {
        switch change.status {
        case .untracked: return "Blame isn't available for an untracked file — it has no history yet"
        case .deleted: return "Blame isn't available — the file no longer exists in the working tree"
        default: break
        }
        if isPreviewable { return "Blame isn't available for a previewed file" }
        if symlinkTarget != nil { return "Blame isn't available for a symlink" }
        if diff == nil { return "Blame isn't available while the diff is loading" }
        if diff?.isBinary == true { return "Blame isn't available for a binary file" }
        return nil
    }

    /// L1: Scope (Hunks/Whole file), Diff mode (Inline/Split) and Wrap all reshape a rendered text
    /// diff — none of them have any effect on `FilePreviewView` or the binary "Content
    /// Unavailable" placeholder, so they're disabled (with the same reason surfaced via `.help`
    /// as the other file-type-gated controls, e.g. `blameDisabledReason`) rather than left clickable
    /// with no visible effect. Same `diff == nil` "unknown yet" treatment as `blameDisabledReason` —
    /// these controls only matter once a text diff is actually showing.
    private var diffShapingDisabledReason: String? {
        if isPreviewable { return "Not shown for a previewed file" }
        if symlinkTarget != nil { return "Not shown for a symlink" }
        if diff?.isBinary == true { return "Not shown for a binary file" }
        return nil
    }

    /// `PreviewKind.kind(for:)` for this file — `text`/`none` (or an unpreviewably large file)
    /// falls through to the existing text diff / "Binary file changed" placeholder.
    private var previewKind: PreviewKind { PreviewKind.kind(for: change.path) }
    private var isPreviewable: Bool { PreviewKind.canPreview(kind: previewKind, size: change.size) }

    /// The disk-touching half of `FileEditor.editability`: stats and (if small enough) reads the
    /// file to answer the pure function's questions. Checks size before reading content so a huge
    /// ineligible file is never actually loaded into memory just to find out it's too big.
    ///
    /// Callers must have already checked `FileEditor.isSymlink(at:)` and short-circuited before
    /// calling this — it's only reached for a non-symlink path, so `fm.fileExists`/`attributesOfItem`
    /// dereferencing here is safe (nothing left to accidentally follow).
    private func fileEditability(for change: FileChange, in repoURL: URL) -> FileEditor.Editability {
        let fileURL = repoURL.appendingPathComponent(change.path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return .notEditable(reason: "File does not exist in the working tree")
        }
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size <= FileEditor.maxEditableBytes else {
            return .notEditable(reason: "File is larger than \(FileEditor.maxEditableBytes / 1_000_000) MB")
        }
        let isValidUTF8: Bool
        if let data = try? Data(contentsOf: fileURL) {
            isValidUTF8 = String(data: data, encoding: .utf8) != nil
        } else {
            isValidUTF8 = false
        }
        return FileEditor.editability(
            fileExists: true,
            isConflicted: change.status == .conflicted,
            isImage: change.isImage,
            fileSize: size,
            isValidUTF8: isValidUTF8
        )
    }

    /// The file's path used to live in the window's `.navigationTitle`, where it competed with
    /// `ChangesView`'s repo name — see the window-title fix in `ContentView`. Shown here instead.
    private var fileHeader: some View {
        HStack(spacing: 8) {
            Text(change.path).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var diffBody: some View {
        Group {
            // M9: checked first, ahead of Edit/Blame/diff — a symlink is never editable and never
            // read through (see `FileEditor.isSymlink`'s doc comment), so nothing past this point
            // may try to size or read the working-tree path. `isEditing`/`blame` can't actually be
            // true here in practice (their toggles are disabled via `editability`/
            // `blameDisabledReason` while `symlinkTarget != nil`), but this ordering also protects
            // against a genuine edge case: `initialBlame`'s test-only seam bypasses that toggle.
            if let symlinkTarget {
                ContentUnavailableView {
                    Label("Symbolic link", systemImage: "arrow.triangle.turn.up.right.diamond")
                } description: {
                    // The target is shown, never its contents: a committed link to e.g. ~/.ssh
                    // would otherwise display a private file under an innocent name.
                    Text("Points to \(symlinkTarget)").font(.callout.monospaced()).textSelection(.enabled)
                }
            } else if isEditing {
                EditFileView(
                    fileURL: repo.url.appendingPathComponent(change.path),
                    editSession: editSession,
                    onSaved: { reloadToken += 1 },
                    onLoadFailed: { isEditing = false }
                )
            } else if blame {
                if blameLoading && blameResult == nil {
                    ProgressView()
                } else if let blameResult {
                    BlameBodyView(
                        result: blameResult,
                        fileExtension: (change.path as NSString).pathExtension,
                        wrap: wrap,
                        onSelectCommit: { line in onNavigateToBlameCommit(line.commitHash) }
                    )
                } else {
                    ContentUnavailableView("Could not load blame", systemImage: "exclamationmark.triangle")
                }
            } else if change.status == .conflicted {
                // `git diff` on a conflicted path returns a combined ("diff --cc") diff — both
                // sides collapsed onto shared line numbers with a second `+`/`-` gutter column —
                // which is accurate but not what anyone means by "show me the conflict"; verified
                // against a real merge conflict in a temp repo. The working-tree file with its
                // `<<<<<<<`/`=======`/`>>>>>>>` markers is the thing the user actually needs to
                // read, so that's what this shows instead, with the two sides visually split.
                if let conflictSegments {
                    ConflictMarkupView(segments: conflictSegments)
                } else {
                    ProgressView()
                }
            } else if loading && diff == nil {
                ProgressView()
            } else if let diff {
                if isPreviewable {
                    FilePreviewView(repo: repo, path: change.path, kind: previewKind, before: previewBefore, after: previewAfter)
                } else if diff.isBinary {
                    ContentUnavailableView("Binary file changed", systemImage: "doc.zipper")
                } else if diff.hunks.isEmpty {
                    ContentUnavailableView("No textual changes", systemImage: "doc")
                } else {
                    DiffBodyView(
                        diff: diff, mode: mode,
                        fileExtension: (change.path as NSString).pathExtension,
                        isWholeFile: wholeFile,
                        wrap: wrap,
                        // A whole-file diff is one giant hunk covering the entire file — "stage
                        // hunk" on it would stage the whole file, which is misleading (and
                        // redundant with the regular per-file stage action), so hide it there.
                        hunkActionLabel: wholeFile ? nil : hunkActionLabel,
                        hunkAction: (wholeFile || hunkActionLabel == nil) ? nil : { hunk in
                            Task {
                                if change.area == .staged { await repo.unstageHunk(hunk, of: change) }
                                else { await repo.stageHunk(hunk, of: change) }
                                reloadToken += 1
                            }
                        },
                        // Unlike hunk staging, line staging stays on in whole-file mode: the patch
                        // is built from the selected lines only (the rest becomes context or is
                        // dropped), so the size of the enclosing hunk doesn't matter.
                        lineActions: lineActions(for: diff)
                    )
                }
            } else {
                ContentUnavailableView("Could not load diff", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// The repo's current record for this file, falling back to the one we were handed if it has
    /// since disappeared from the list (e.g. right after it was fully staged/discarded).
    private var currentChange: FileChange {
        repo.changesByID[change.id] ?? change
    }

    private func lineActions(for diff: FileDiff) -> DiffLineActions? {
        guard RepositoryStore.supportsLineActions(change) else { return nil }
        let change = change
        return DiffLineActions(path: change.path, ops: change.area == .staged ? [.unstage] : [.stage, .discard]) { op, lines in
            Task {
                switch op {
                case .stage: await repo.stageLines(lines, in: diff, of: change)
                case .unstage: await repo.unstageLines(lines, in: diff, of: change)
                case .discard: await repo.discardLines(lines, in: diff, of: change)
                }
                reloadToken += 1
            }
        }
    }

    private var hunkActionLabel: String? {
        guard change.status == .modified else { return nil }
        return change.area == .staged ? "Unstage hunk" : "Stage hunk"
    }
}

/// Renders a conflicted file's `ConflictSegment`s: plain text runs as-is, and each conflict block
/// as its two sides stacked with the same added/removed backgrounds `DiffBodyView` uses elsewhere,
/// so "which side is which" reads the same way a diff does. This is intentionally not a merge
/// editor — no accept/reject per-line, no editing — just enough visual structure that the markers
/// are legible; the real resolution happens in a text editor (`Open in Editor`) or via "Use mine"
/// / "Use theirs" in the Conflicts section.
private struct ConflictMarkupView: View {
    let segments: [ConflictSegment]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .context(let lines):
                        linesView(lines, background: .clear)
                    case .conflict(let ours, let theirs):
                        sideHeader(ours.label.isEmpty ? "Ours" : ours.label)
                        linesView(ours.lines, background: Theme.diffRemoved)
                        sideHeader(theirs.label.isEmpty ? "Theirs" : theirs.label)
                        linesView(theirs.lines, background: Theme.diffAdded)
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(.vertical, 4)
        }
    }

    private func sideHeader(_ label: String) -> some View {
        Text(label)
            .font(.caption.monospaced().bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private func linesView(_ lines: [String], background: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .background(background)
    }
}

/// A diff toolbar's text toggle. The toolbar draws its own native capsule/glass bezel around it (a
/// custom background here would double up into a pill-inside-a-pill); the label carries state:
/// `Theme.brand` + semibold when on, `.secondary` otherwise. `Theme.brand`,
/// not `Color.accentColor` — the latter is the *system* accent and ignores the app's `.tint`.
/// Generalized out of what used to be a Wrap-only `WrapToggle` so Blame (T3) reuses the exact same
/// control instead of a second bespoke one.
struct ToolbarToggle: View {
    let label: String
    @Binding var isOn: Bool
    var help: String

    var body: some View {
        // A plain `Button`, not `Toggle(.button)`: in an active window macOS 26 fills an "on"
        // toolbar toggle with the tint — `Theme.brand` — putting brand-orange text on a
        // brand-orange capsule. A Button keeps the same neutral bezel in both states, so the
        // label alone carries state and is always readable.
        Button { isOn.toggle() } label: {
            Text(label)
                .fontWeight(isOn ? .semibold : .regular)
                .foregroundStyle(isOn ? Theme.brand : Color.secondary)
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(help)
    }
}

struct WrapToggle: View {
    @Binding var isOn: Bool
    var body: some View { ToolbarToggle(label: "Wrap", isOn: $isOn, help: "Wrap long lines") }
}
