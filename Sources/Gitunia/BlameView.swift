import SwiftUI
import GituniaCore

/// Renders a `BlameResult` for `DiffView`'s Blame toggle: a left gutter (short hash, author,
/// relative date) shown once per run of consecutive lines from the same commit — via
/// `BlameGrouping.rows(for:)`, a pure function tested on its own — a line number, and the
/// syntax-highlighted line text (reusing `LineText`/`SyntaxHighlighter`, same as the diff body).
struct BlameBodyView: View {
    let result: BlameResult
    var fileExtension: String? = nil
    var wrap: Bool = false
    /// Fires for a click on a committed line's gutter — `DiffView` routes this to
    /// `ContentView.requestFileHistory`-style navigation into History. Uncommitted lines never
    /// call this (there's no commit to jump to).
    var onSelectCommit: (BlameLine) -> Void = { _ in }

    var body: some View {
        let rows = BlameGrouping.rows(for: result.lines)
        // Same `GeometryReader` + explicit `minWidth`/`minHeight` shape `DiffBodyView` uses — a
        // bare `ScrollView` doesn't reliably claim the full height of a `VStack` sibling (the
        // content would otherwise end up vertically centered in the pane instead of starting
        // right under the divider), so the reader's measured size is threaded through the same way.
        GeometryReader { geo in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if result.truncated {
                        HunkHeaderRow(text: "File truncated (showing \(result.lines.count) of \(result.totalLines) lines).")
                    }
                    ForEach(Array(zip(result.lines, rows).enumerated()), id: \.offset) { _, pair in
                        BlameLineRow(line: pair.0, info: pair.1, fileExtension: fileExtension, wrap: wrap,
                                     onSelect: { onSelectCommit(pair.0) })
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}

private struct BlameLineRow: View {
    let line: BlameLine
    let info: BlameRowInfo
    var fileExtension: String?
    var wrap: Bool
    let onSelect: () -> Void

    private var bandColor: Color {
        if line.isUncommitted { return Theme.brand.opacity(0.16) }
        return info.band.isMultiple(of: 2) ? Theme.gutterBackground : Theme.diffContextBackground
    }

    private var relativeDate: String { RelativeDate.string(for: Date(timeIntervalSince1970: line.authorTime)) }

    var body: some View {
        HStack(spacing: 0) {
            gutter
                .frame(width: 190, alignment: .leading)
                .padding(.vertical, 1).padding(.horizontal, 6)
                .background(bandColor)
                .contentShape(Rectangle())
                .onTapGesture { if !line.isUncommitted { onSelect() } }
                .help(line.isUncommitted ? "Not committed yet" : line.summary)
            Divider()
            Gutter(number: line.lineNumber)
            LineText(text: line.text, fileExtension: fileExtension, wrap: wrap)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var gutter: some View {
        if info.isRunStart {
            if line.isUncommitted {
                Text("Not committed yet")
                    .font(.caption)
                    .foregroundStyle(Theme.brand)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Text(String(line.commitHash.prefix(7)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(line.author)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(relativeDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
