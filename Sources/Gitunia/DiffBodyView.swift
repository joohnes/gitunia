import SwiftUI
import GituniaCore

enum DiffMode: String, CaseIterable {
    case inline, split
    var label: String { self == .inline ? "Inline" : "Split" }
}

/// Identity strings for the diff's rows and sections.
///
/// `mode` is part of both on purpose. Inline row N and split row N used to produce the same
/// string, so across the `switch mode` branches SwiftUI matched the identities and reused the
/// previous branch's views — which is how one file ended up rendering inline while another
/// rendered split. Salting with the diff's own hash likewise stops a row surviving into a
/// different diff.
enum DiffRowID {
    static func row(mode: DiffMode, diffHash: Int, hunk: Int, line: Int) -> String {
        "\(mode.rawValue)-\(diffHash)-\(hunk)-\(line)"
    }

    static func section(mode: DiffMode, key: String) -> String {
        "\(mode.rawValue)-\(key)"
    }
}

/// M4: memoizes `DiffBodyView.highlightRanges(for:lines:)` — an O(n·m) LCS per changed section —
/// keyed per `(diff, section)` so a re-render that doesn't change the diff itself (selecting a
/// line, expanding a collapsed section elsewhere in the file) doesn't redo that work for every
/// section SwiftUI still considers current. Whole cache is dropped in one shot whenever the diff's
/// hash changes, rather than tracked per-entry, since a new diff invalidates every section anyway.
/// Plain class (not `Observable`/`@Published`) so writing into it during `body`'s evaluation is
/// inert as far as SwiftUI's own invalidation is concerned — only the `@State` box holding this
/// instance participates in that, and it never changes.
private final class HighlightRangeCache {
    private var diffHash: Int?
    private var entries: [String: [DiffLine: [Range<String.Index>]]] = [:]

    func ranges(
        diffHash: Int, key: String, compute: () -> [DiffLine: [Range<String.Index>]]
    ) -> [DiffLine: [Range<String.Index>]] {
        if self.diffHash != diffHash {
            self.diffHash = diffHash
            entries.removeAll()
        }
        if let cached = entries[key] { return cached }
        let result = compute()
        entries[key] = result
        return result
    }
}

/// Renders a FileDiff's hunks. Shared by the working-tree diff and the commit diff.
struct DiffBodyView: View {
    let diff: FileDiff
    let mode: DiffMode
    var fileExtension: String? = nil
    var isWholeFile: Bool = false
    var wrap: Bool = false
    var hunkActionLabel: String? = nil
    var hunkAction: ((Hunk) -> Void)? = nil
    /// Line-level stage/unstage/discard; nil = lines aren't selectable (see `LineSelectionBar`).
    var lineActions: DiffLineActions? = nil
    /// Test-only seam for the render harness (production never passes it).
    var initialLineSelection: Set<DiffLineRef> = []

    // T0 item 2: same reasoning as `ChangesView`'s `s`/`u` guard — `.focusable(!isPaletteOpen)`
    // stops this view from becoming first responder while the palette owns the keyboard, and the
    // `onKeyPress` guard below is the belt-and-suspenders backstop.
    @Environment(\.isPaletteOpen) private var isPaletteOpen

    private static let maxLines = 3000
    // Whole-file mode routinely shows files well past the ordinary hunk-context cap, so it gets
    // a much higher one — this is a length-of-file cap, not a "how big can a diff get" cap.
    private static let maxLinesWholeFile = 20_000
    private var maxLines: Int { isWholeFile ? Self.maxLinesWholeFile : Self.maxLines }

    // Hunks have no stable identity of their own (see Models.swift), so the index into this
    // file's hunk array is the anchor id — stable for the lifetime of one diff, reset below
    // whenever the diff itself changes (new file, or same file reloaded after a stage/unstage).
    @State private var currentHunkIndex = 0
    // Index into DiffRegions.changedRegions(...) for the single-hunk case (always true in
    // whole-file mode, sometimes true otherwise) — see `jump` below.
    @State private var currentRegionIndex = 0
    // Which collapsible unchanged sections are expanded, keyed the same diff-hash-salted way as
    // row ids below (see `SectionInfo.key`) so a key from a previous diff never applies to this
    // one — and reset explicitly on diff change so the set doesn't grow forever.
    @State private var expandedSectionKeys: Set<String> = []
    // Line selection (gutter click / shift / ⌘). Refs index `diff` (not `shown` — truncation only
    // clips a suffix, and clipped hunks aren't selectable), cleared on diff change below.
    @State private var selectedLines: Set<DiffLineRef> = []
    @State private var lineAnchor: DiffLineRef?
    @FocusState private var diffFocused: Bool
    // M4: word-level LCS results, keyed the same diff-hash-salted way as `SectionInfo.key` and
    // invalidated the same way row ids are — by the diff's own hash, not by an explicit reset —
    // so a re-render triggered by unrelated `@State` (line selection, expand/collapse) reuses the
    // previous LCS work instead of recomputing it. A plain (non-`Observable`) class, not `@State`
    // holding a dictionary directly: mutating it inside `sectionInfos` (called from `body`) must
    // not itself trigger a SwiftUI re-render, or every cache-miss would recursively invalidate.
    @State private var highlightCache = HighlightRangeCache()

    // In whole-file mode, long unchanged runs collapse (see DiffSections); an ordinary hunk's
    // three lines of context never clear the threshold, so passing `.max` there is a no-op that
    // keeps this view's normal-mode output byte-for-byte identical to before this feature.
    private var collapseThreshold: Int { isWholeFile ? 12 : .max }

    var body: some View {
        let (shown, total) = diff.truncated(toLines: maxLines)
        ScrollViewReader { proxy in
            GeometryReader { geo in
                // Wrapping and horizontal scrolling don't mix: with wrap on, rows are
                // width-constrained to the viewport and only vertical scroll is offered; with
                // wrap off (the default), rows size to their content and can scroll sideways, as
                // before this feature existed.
                if wrap {
                    ScrollView(.vertical) {
                        diffContent(shown: shown, total: total, width: geo.size.width)
                            .frame(maxWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        diffContent(shown: shown, total: total, width: geo.size.width)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .focusable(!isPaletteOpen)
            .focused($diffFocused)
            .focusEffectDisabled()
            // Same guard as ChangesView's s/u: attached to the scrollable diff area itself, so
            // j/k only fire while this view holds focus, not while some other text field does.
            .onKeyPress("j") {
                guard !isPaletteOpen else { return .ignored }
                jump(by: 1, shown: shown, proxy: proxy); return .handled
            }
            .onKeyPress("k") {
                guard !isPaletteOpen else { return .ignored }
                jump(by: -1, shown: shown, proxy: proxy); return .handled
            }
            // s/u act on the line selection while the diff holds focus (a gutter click focuses
            // it); with no selection they fall through, leaving ChangesView's file-level s/u.
            .onKeyPress("s") { runLineAction(.stage) }
            .onKeyPress("u") { runLineAction(.unstage) }
            .onKeyPress(.escape) {
                guard !isPaletteOpen, !selectedLines.isEmpty else { return .ignored }
                clearLineSelection(); return .handled
            }
            .overlay(alignment: .bottom) {
                if let lineActions, !selectedLines.isEmpty {
                    LineSelectionBar(count: selectedLines.count, actions: lineActions,
                                     run: { op in _ = runLineAction(op, fromKey: false) },
                                     clear: clearLineSelection)
                }
            }
        }
        .font(.system(.body, design: .monospaced))
        .onChange(of: diff) { currentHunkIndex = 0; currentRegionIndex = 0; expandedSectionKeys = []; clearLineSelection() }
        .onAppear { if !initialLineSelection.isEmpty { selectedLines = initialLineSelection } }
    }

    @ViewBuilder
    private func diffContent(shown: FileDiff, total: Int, width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.hunks.enumerated()), id: \.offset) { index, hunk in
                let actionLabel = hunk.isClipped ? nil : hunkActionLabel
                HunkHeaderRow(text: hunk.header, actionLabel: actionLabel) { hunkAction?(hunk) }
                    .id(index)
                let infos = sectionInfos(for: hunk, hunkIndex: index)
                switch mode {
                case .inline:
                    ForEach(infos, id: \.identity) { info in
                        sectionInlineView(info: info, hunkIndex: index, selectable: lineActions != nil && !hunk.isClipped)
                    }
                case .split:
                    ForEach(infos, id: \.identity) { info in
                        sectionSplitView(info: info, hunkIndex: index, width: width, selectable: lineActions != nil && !hunk.isClipped)
                    }
                }
            }
            if total > maxLines {
                let noun = isWholeFile ? "File" : "Diff"
                HunkHeaderRow(text: "\(noun) truncated (showing \(maxLines) of \(total) lines). Open the file in your editor to see everything.")
            }
        }
    }

    // Row identity is salted with the diff's own hash so a row never survives into a different
    // diff (new file, or this file reloaded after staging) reusing stale content. Not wrapped
    // around the whole ScrollView, so scroll position survives an in-place reload; only row
    // content/selection does not.
    private func rowID(diffHash: Int, hunk: Int, line: Int) -> String {
        DiffRowID.row(mode: mode, diffHash: diffHash, hunk: hunk, line: line)
    }

    /// One of `DiffSections.sections(for:)`'s outputs, plus enough bookkeeping to place it back
    /// into the row-id scheme above as if nothing had collapsed. `lineOffset`/`rowOffset` are the
    /// position this section's first line/row would have in the *uncollapsed* inline/split
    /// rendering of the whole hunk — i.e. plain running totals over every section in order,
    /// whether or not that section ends up rendered as individual rows. That is what keeps
    /// `jump(by:)` (which computes its target against the full, uncollapsed hunk) landing on the
    /// right id even when a section between here and there is collapsed and therefore never
    /// instantiates its own rows.
    ///
    /// `highlights` maps a changed section's lines to the word-level ranges (in that line's own
    /// `text`) that differ from its paired line, per `InlineDiff` — computed once here, alongside
    /// the section split itself, rather than inside every row's `body` (which SwiftUI re-runs on
    /// every redraw). Keyed by the `DiffLine` value itself (its line numbers make it unique
    /// within a diff) so both inline rows and split's left/right cells can look themselves up
    /// without tracking a separate index.
    private struct SectionInfo {
        let section: DiffSection
        let lineOffset: Int
        let rowOffset: Int
        /// Keys the user's expand/collapse state. Deliberately free of the diff mode so a section
        /// the user expanded stays expanded across an Inline/Split switch.
        let key: String
        /// What `ForEach` matches on. Mode-salted, because an inline section and a split section
        /// at the same position are different views and must not inherit each other's rows.
        let identity: String
        let highlights: [DiffLine: [Range<String.Index>]]
    }

    private func sectionInfos(for hunk: Hunk, hunkIndex: Int) -> [SectionInfo] {
        let sections = DiffSections.sections(for: hunk.lines, collapseThreshold: collapseThreshold)
        var lineOffset = 0
        var rowOffset = 0
        return sections.enumerated().map { i, section in
            let lines = sectionLines(section)
            let key = "\(diff.hashValue)-\(hunkIndex)-\(i)"
            let highlights = highlightCache.ranges(diffHash: diff.hashValue, key: key) {
                highlightRanges(for: section, lines: lines)
            }
            let info = SectionInfo(section: section, lineOffset: lineOffset, rowOffset: rowOffset,
                                    key: key, identity: DiffRowID.section(mode: mode, key: key),
                                    highlights: highlights)
            lineOffset += lines.count
            rowOffset += SideBySide.rows(for: Hunk(header: "", lines: lines)).count
            return info
        }
    }

    private func sectionLines(_ section: DiffSection) -> [DiffLine] {
        switch section {
        case .changed(let lines): return lines
        case .unchanged(let lines, _): return lines
        }
    }

    /// Word-level highlight ranges for a changed section's removed/added line pairs. Unchanged
    /// sections never highlight (nothing changed within them). A pair whose `InlineDiff` result
    /// fell back to whole-line comparison (the two lines are too dissimilar, or one of them is
    /// empty) is skipped: re-tinting a whole line that's already whole-line-tinted by
    /// `lineBackground` achieves nothing.
    private func highlightRanges(for section: DiffSection, lines: [DiffLine]) -> [DiffLine: [Range<String.Index>]] {
        guard case .changed = section else { return [:] }
        var result: [DiffLine: [Range<String.Index>]] = [:]
        for pair in InlineDiff.pairs(in: lines) {
            let removedLine = lines[pair.removedIndex]
            let addedLine = lines[pair.addedIndex]
            let wordRanges = InlineDiff.wordRanges(removed: removedLine.text, added: addedLine.text)
            if wordRanges.didFallBack { continue }
            if !wordRanges.removed.isEmpty { result[removedLine] = wordRanges.removed }
            if !wordRanges.added.isEmpty { result[addedLine] = wordRanges.added }
        }
        return result
    }

    @ViewBuilder
    private func sectionInlineView(info: SectionInfo, hunkIndex: Int, selectable: Bool) -> some View {
        if case .unchanged(let lines, true) = info.section, !expandedSectionKeys.contains(info.key) {
            CollapsedSectionRow(count: lines.count) { toggleExpanded(info.key) }
        } else {
            let lines = sectionLines(info.section)
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let ref = DiffLineRef(hunk: hunkIndex, line: info.lineOffset + i)
                DiffLineRow(line: line, fileExtension: fileExtension, wrap: wrap,
                            highlightRanges: info.highlights[line] ?? [],
                            isSelected: selectedLines.contains(ref),
                            onGutterTap: selectable && line.kind != .context ? { gutterTapped(ref) } : nil)
                    .id(rowID(diffHash: diff.hashValue, hunk: hunkIndex, line: info.lineOffset + i))
            }
        }
    }

    @ViewBuilder
    private func sectionSplitView(info: SectionInfo, hunkIndex: Int, width: CGFloat, selectable: Bool) -> some View {
        if case .unchanged(let lines, true) = info.section, !expandedSectionKeys.contains(info.key) {
            CollapsedSectionRow(count: lines.count) { toggleExpanded(info.key) }
                .frame(width: width)
        } else {
            let lines = sectionLines(info.section)
            let rows = SideBySide.rows(for: Hunk(header: "", lines: lines))
            // DiffLine values are unique within a hunk (their line numbers), so a split cell can
            // find its own ref without positional bookkeeping.
            let refs = selectable ? Dictionary(lines.enumerated().map { ($1, DiffLineRef(hunk: hunkIndex, line: info.lineOffset + $0)) },
                                               uniquingKeysWith: { a, _ in a }) : [:]
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                SplitRow(row: row, fileExtension: fileExtension, width: width, wrap: wrap, highlights: info.highlights,
                         isSelected: { refs[$0].map(selectedLines.contains) ?? false },
                         onGutterTap: selectable ? { line in if line.kind != .context, let ref = refs[line] { gutterTapped(ref) } } : nil)
                    .id(rowID(diffHash: diff.hashValue, hunk: hunkIndex, line: info.rowOffset + i))
            }
        }
    }

    private func gutterTapped(_ ref: DiffLineRef) {
        let flags = NSEvent.modifierFlags
        (selectedLines, lineAnchor) = DiffLineSelection.click(ref, extend: flags.contains(.shift), toggle: flags.contains(.command),
                                                              selection: selectedLines, anchor: lineAnchor, in: diff)
        diffFocused = true
    }

    private func clearLineSelection() {
        selectedLines = []
        lineAnchor = nil
    }

    /// Runs `op` on the current selection if this diff offers it; the selection is cleared right
    /// away (the reload that follows would clear it anyway, via the diff change).
    private func runLineAction(_ op: DiffLineActions.Op, fromKey: Bool = true) -> KeyPress.Result {
        guard !(fromKey && isPaletteOpen), let lineActions, lineActions.ops.contains(op), !selectedLines.isEmpty else { return .ignored }
        lineActions.perform(op, selectedLines)
        clearLineSelection()
        return .handled
    }

    private func toggleExpanded(_ key: String) {
        if expandedSectionKeys.contains(key) { expandedSectionKeys.remove(key) } else { expandedSectionKeys.insert(key) }
    }

    /// With more than one hunk, j/k page between hunk headers as before. With exactly one hunk —
    /// always true in whole-file mode, where there is nothing else to jump between — j/k instead
    /// pages between changed regions (maximal runs of added/removed lines) within that hunk, via
    /// `DiffRegions.changedRegions`, which is the actually-useful behavior when "next hunk" is a
    /// no-op. Multi-hunk jump targets a hunk header's `.id(index)`; single-hunk jump targets a
    /// line row's `.id(rowID(...))`, resolved by finding that line's position in the row sequence
    /// this mode actually renders (identical to the line index in inline mode; found by matching
    /// the DiffLine value in split mode, since split can merge/pair lines into fewer rows).
    /// Wrapping changes row *heights*, not row identity or count, so this targeting is unaffected
    /// by the wrap toggle — `scrollTo(_:anchor: .top)` still lands on the right row, just a taller
    /// or shorter one.
    private func jump(by delta: Int, shown: FileDiff, proxy: ScrollViewProxy) {
        guard let hunk = shown.hunks.first else { return }
        if shown.hunks.count > 1 {
            currentHunkIndex = min(max(currentHunkIndex + delta, 0), shown.hunks.count - 1)
            proxy.scrollTo(currentHunkIndex, anchor: .top)
            return
        }
        let regions = DiffRegions.changedRegions(in: hunk.lines)
        guard !regions.isEmpty else { return }
        currentRegionIndex = min(max(currentRegionIndex + delta, 0), regions.count - 1)
        let targetLineIndex = regions[currentRegionIndex].lowerBound
        let rowIndex: Int
        switch mode {
        case .inline:
            rowIndex = targetLineIndex
        case .split:
            let targetLine = hunk.lines[targetLineIndex]
            let rows = SideBySide.rows(for: hunk)
            rowIndex = rows.firstIndex { $0.left == targetLine || $0.right == targetLine } ?? 0
        }
        proxy.scrollTo(rowID(diffHash: diff.hashValue, hunk: 0, line: rowIndex), anchor: .top)
    }
}

struct HunkHeaderRow: View {
    let text: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gutterBackground)
    }
}

/// A collapsed unchanged section, rendered as one clickable row — matches HunkHeaderRow's style
/// so it reads as the same kind of "structural" row rather than a line of the file.
struct CollapsedSectionRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("⋯ \(count) unchanged line\(count == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.gutterBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    var fileExtension: String? = nil
    var wrap: Bool = false
    var highlightRanges: [Range<String.Index>] = []
    var isSelected: Bool = false
    /// Set only for selectable (changed) lines — the gutter then selects the line.
    var onGutterTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Gutter(number: line.oldNumber)
                Gutter(number: line.newNumber)
                Text(marker(line.kind))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
            }
            .modifier(GutterSelection(isSelected: isSelected, onTap: onGutterTap))
            LineText(text: line.text, fileExtension: fileExtension, wrap: wrap,
                     highlightRanges: highlightRanges, highlightColor: highlightBackground(line.kind))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(line.kind, weakened: !highlightRanges.isEmpty))
        .overlay { if isSelected { Theme.brand.opacity(0.18).allowsHitTesting(false) } }
    }
}

private struct SplitRow: View {
    let row: SideBySideRow
    var fileExtension: String?
    let width: CGFloat
    var wrap: Bool = false
    var highlights: [DiffLine: [Range<String.Index>]] = [:]
    var isSelected: (DiffLine) -> Bool = { _ in false }
    var onGutterTap: ((DiffLine) -> Void)? = nil

    private var half: CGFloat { max((width - 1) / 2, 200) }

    var body: some View {
        // Left/right cells align to `.top` rather than the HStack default `.center` so that, in
        // wrap mode, a cell whose line wrapped to more rows than its counterpart doesn't push its
        // first line down — both start flush with the row's top edge, the way single-line rows
        // already read.
        HStack(alignment: .top, spacing: 0) {
            cell(row.left, number: row.left?.oldNumber)
            Divider()
            cell(row.right, number: row.right?.newNumber)
        }
        .frame(width: width)
    }

    private func cell(_ line: DiffLine?, number: Int?) -> some View {
        let selected = line.map(isSelected) ?? false
        return HStack(spacing: 0) {
            Gutter(number: number)
                .modifier(GutterSelection(isSelected: selected,
                                          onTap: line.flatMap { l in onGutterTap.map { tap in { tap(l) } } }))
            if let line {
                LineText(text: line.text, fileExtension: fileExtension, wrap: wrap,
                          highlightRanges: highlights[line] ?? [], highlightColor: highlightBackground(line.kind))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(width: half, alignment: .leading)
        // In wrap mode, cells grow to fit their own wrapped text; without a constraint the taller
        // side of a pair would simply be taller than the shorter one with no relation between the
        // two, so both sides are asked to fill the row's own height (`.infinity`, top-aligned) —
        // the row height still comes from whichever side actually needs more room (HStack sizes
        // itself to its tallest child), and the shorter side's background stretches to match it,
        // keeping the divider and every following row pairwise aligned. Unwrapped rows are a
        // single fixed-height line on both sides already, so this is a no-op there; `.clipped()`
        // only applies unwrapped, where it exists to crop a fixedSize line wider than its cell.
        .frame(maxHeight: wrap ? .infinity : nil, alignment: .top)
        .modifier(ClippedIf(active: !wrap))
        .background(line.map { lineBackground($0.kind, weakened: !(highlights[$0]?.isEmpty ?? true)) } ?? Theme.diffContextBackground)
        .overlay { if selected { Theme.brand.opacity(0.18).allowsHitTesting(false) } }
    }
}

/// `.clipped()` only makes sense for the fixed single-line height used when not wrapping — in
/// wrap mode a cell's height is meant to grow, so clipping it would cut off wrapped lines.
private struct ClippedIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.clipped() } else { content }
    }
}

struct Gutter: View {
    let number: Int?
    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

/// Renders a diff line's text with syntax-highlighted foreground colors (from
/// `SyntaxHighlighter.tokens`) and, optionally, a stronger background behind the word-level
/// ranges that actually changed (from `InlineDiff`).
struct LineText: View {
    let text: String
    var fileExtension: String?
    var wrap: Bool = false
    var highlightRanges: [Range<String.Index>] = []
    var highlightColor: Color? = nil

    var body: some View {
        if wrap {
            // No lineLimit/fixedSize: the Text wraps to whatever width its container proposes,
            // which the caller (DiffBodyView, in wrap mode) constrains to the viewport.
            Text(highlighted)
                .textSelection(.enabled)
        } else {
            Text(highlighted)
                .textSelection(.enabled)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var highlighted: AttributedString {
        let language = SyntaxLanguage.from(fileExtension: fileExtension)
        var result = AttributedString()
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            var piece = AttributedString(String(text[token.range]))
            piece.foregroundColor = Theme.syntax(token.kind)
            result.append(piece)
        }
        if result.characters.isEmpty { result = AttributedString(text) }

        // `highlightRanges` are `String.Index` values into `text`; `result`'s own index type is
        // unrelated (AttributedString has its own index space) even though both walk the same
        // sequence of Characters. `text` and `result` contain exactly the same characters in the
        // same order — the token loop above partitions `text` completely (SyntaxHighlighter emits
        // a `.plain` run over every gap) — so a character *offset* computed against `text` lands
        // on the same character in `result`. Going through the offset rather than assuming the
        // index values are interchangeable is what keeps this correct for multi-scalar characters
        // (emoji, accented letters composed of multiple Unicode scalars): `String.Index` and
        // `AttributedString.Index` both count Characters (grapheme clusters), not UTF-8/UTF-16
        // code units, but they are still distinct index types over distinct storage.
        if let highlightColor {
            for range in highlightRanges {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                guard length > 0,
                      let rStart = result.characters.index(result.startIndex, offsetBy: start, limitedBy: result.endIndex),
                      let rEnd = result.characters.index(rStart, offsetBy: length, limitedBy: result.endIndex) else { continue }
                result[rStart..<rEnd].backgroundColor = highlightColor
            }
        }
        return result
    }
}

func marker(_ kind: DiffLine.Kind) -> String {
    switch kind {
    case .added: "+"
    case .removed: "-"
    case .context: " "
    }
}

/// The whole-row tint. `weakened` (used when the row also carries a word-level highlight, see
/// `highlightBackground`) halves the opacity so the strong color reads as belonging to the
/// changed tokens specifically, while the row around them still clearly reads as added/removed —
/// chosen over adding new "strong" colors to `Theme` because the two-strength effect this task
/// wants falls straight out of one color at two opacities, and `Theme` has no such members today.
func lineBackground(_ kind: DiffLine.Kind, weakened: Bool = false) -> Color {
    switch kind {
    case .added: Theme.diffAdded.opacity(weakened ? 0.5 : 1)
    case .removed: Theme.diffRemoved.opacity(weakened ? 0.5 : 1)
    case .context: .clear
    }
}

/// Full-strength color for the word-level highlight itself — same color `lineBackground` used to
/// use for the whole row before this task, just now reserved for the differing characters.
private func highlightBackground(_ kind: DiffLine.Kind) -> Color? {
    switch kind {
    case .added: Theme.diffAdded
    case .removed: Theme.diffRemoved
    case .context: nil
    }
}
