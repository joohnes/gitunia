import Foundation

public struct SideBySideRow: Hashable, Sendable {
    public let left: DiffLine?
    public let right: DiffLine?
    public init(left: DiffLine?, right: DiffLine?) { self.left = left; self.right = right }
}

public enum SideBySide {
    /// Pairs each run of removed lines with the following run of added lines, index by index.
    public static func rows(for hunk: Hunk) -> [SideBySideRow] {
        let lines = hunk.lines
        let runs = DiffLine.runs(lines, by: \.kind)
        var rows: [SideBySideRow] = []
        var k = 0
        while k < runs.count {
            let run = runs[k]
            k += 1
            if run.key == .context { rows += lines[run.range].map { SideBySideRow(left: $0, right: $0) }; continue }
            var removed = run.key == .removed ? lines[run.range] : [], added = run.key == .added ? lines[run.range] : []
            if run.key == .removed, k < runs.count, runs[k].key == .added { added = lines[runs[k].range]; k += 1 }
            for i in 0..<max(removed.count, added.count) {
                rows.append(SideBySideRow(left: i < removed.count ? removed[removed.startIndex + i] : nil,
                                          right: i < added.count ? added[added.startIndex + i] : nil))
            }
        }
        return rows
    }
}
