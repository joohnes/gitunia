import Foundation

/// A hunk's lines grouped into alternating changed and unchanged runs, so a view can collapse
/// long stretches of untouched context (whole-file mode's single giant hunk, in particular)
/// without losing the lines right next to an edit.
public enum DiffSection: Sendable, Equatable {
    case changed([DiffLine])
    case unchanged([DiffLine], collapsible: Bool)
}

public enum DiffSections {
    /// A collapsible remainder shorter than this hides fewer lines than the "show more" row
    /// costs in UI chrome — not worth it, so the run is left fully visible instead. Chosen as
    /// 2x the default padding: a collapsed chunk should hide at least as much on its own as the
    /// two padding strips around it show combined.
    private static let minimumCollapsedSize = 8

    /// Groups `lines` into maximal runs of context vs. changed lines, in order. A context run
    /// longer than `collapseThreshold` is split into up to three pieces: `padding` lines of
    /// visible context next to each adjoining changed region, and a `collapsible: true` middle
    /// section for the rest. A run with no changed region on one side (the very start or end of
    /// the hunk) only gets padding on the side that has one — the far side isn't adjacent to
    /// anything worth showing. If the middle would be smaller than a minimum, the whole run is
    /// left as one visible, non-collapsible section instead.
    ///
    /// Concatenating every returned section's lines reproduces `lines` exactly.
    public static func sections(for lines: [DiffLine],
                                 collapseThreshold: Int = 12,
                                 padding: Int = 4) -> [DiffSection] {
        let runs = DiffLine.runs(lines) { $0.kind == .context }.map { (isContext: $0.key, lines: Array(lines[$0.range])) }

        var sections: [DiffSection] = []
        for (i, run) in runs.enumerated() {
            guard run.isContext else {
                sections.append(.changed(run.lines))
                continue
            }
            let hasChangeBefore = i > 0
            let hasChangeAfter = i < runs.count - 1
            let paddingSides = (hasChangeBefore ? 1 : 0) + (hasChangeAfter ? 1 : 0)
            let paddingTotal = padding * paddingSides
            let count = run.lines.count

            guard count > collapseThreshold, count - paddingTotal >= minimumCollapsedSize else {
                sections.append(.unchanged(run.lines, collapsible: false))
                continue
            }

            var rest = run.lines
            if hasChangeBefore {
                sections.append(.unchanged(Array(rest.prefix(padding)), collapsible: false))
                rest.removeFirst(padding)
            }
            var trailing: [DiffLine] = []
            if hasChangeAfter {
                trailing = Array(rest.suffix(padding))
                rest.removeLast(padding)
            }
            sections.append(.unchanged(rest, collapsible: true))
            if hasChangeAfter {
                sections.append(.unchanged(trailing, collapsible: false))
            }
        }
        return sections
    }
}
