import Foundation

public extension FileDiff {
    /// Truncates hunks (in order) to at most `maxLines` total `DiffLine`s.
    /// Returns the truncated diff alongside the original total line count.
    func truncated(toLines maxLines: Int) -> (diff: FileDiff, totalLines: Int) {
        let totalLines = hunks.reduce(0) { $0 + $1.lines.count }
        guard totalLines > maxLines else { return (self, totalLines) }

        var remaining = maxLines
        var newHunks: [Hunk] = []
        for hunk in hunks {
            guard remaining > 0 else { break }
            if hunk.lines.count <= remaining {
                newHunks.append(hunk)
                remaining -= hunk.lines.count
            } else {
                newHunks.append(Hunk(header: hunk.header, lines: Array(hunk.lines.prefix(remaining)), isClipped: true))
                remaining = 0
            }
        }
        return (FileDiff(path: path, isBinary: isBinary, hunks: newHunks), totalLines)
    }
}
