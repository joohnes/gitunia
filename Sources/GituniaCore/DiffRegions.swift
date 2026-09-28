import Foundation

extension DiffLine {
    /// Maximal runs of consecutive lines with the same `key`, in order.
    static func runs<Key: Equatable>(_ lines: [DiffLine], by key: (DiffLine) -> Key) -> [(key: Key, range: Range<Int>)] {
        var runs: [(key: Key, range: Range<Int>)] = []
        for (i, line) in lines.enumerated() {
            let k = key(line)
            if let last = runs.last, last.key == k { runs[runs.count - 1].range = last.range.lowerBound..<i + 1 }
            else { runs.append((k, i..<i + 1)) }
        }
        return runs
    }
}

/// Finds the changed (added/removed) regions within a hunk's lines — used to jump between
/// them with j/k when a hunk has too much context to page through line by line (whole-file
/// mode's single giant hunk, in particular).
public enum DiffRegions {
    /// Maximal runs of non-context lines, in order of appearance. Each range is contiguous.
    public static func changedRegions(in lines: [DiffLine]) -> [Range<Int>] {
        DiffLine.runs(lines) { $0.kind != .context }.filter(\.key).map(\.range)
    }
}
