import Foundation

/// One side of a conflict block: the label git wrote on its marker line (e.g. "HEAD" or a branch
/// name) and the lines between that marker and the next one.
public struct ConflictSide: Hashable, Sendable {
    public let label: String
    public let lines: [String]
    public init(label: String, lines: [String]) {
        self.label = label
        self.lines = lines
    }
}

/// A working-tree file broken into runs of ordinary text and conflict blocks, in file order.
///
/// With `merge.conflictStyle=diff3`/`zdiff3`, git also writes a `|||||||` common-ancestor section
/// inside the block; `ConflictParser` recognizes it so its lines never leak into `ours`/`theirs`
/// (which a one-click "Use mine"/"Use theirs" resolution writes back to the file verbatim), but it
/// isn't surfaced here — nothing in the UI (a display-only markup view, not a merge editor) shows a
/// three-way diff, so keeping the discarded base text alive would be dead weight.
public enum ConflictSegment: Hashable, Sendable {
    case context(lines: [String])
    case conflict(ours: ConflictSide, theirs: ConflictSide)
}

/// Splits a conflicted working-tree file on git's `<<<<<<<`/`=======`/`>>>>>>>` markers, and, with
/// `merge.conflictStyle=diff3` or `zdiff3`, the additional `|||||||` common-ancestor marker. Pure
/// and testable, following `StatusParser`/`LogParser`'s pattern of a stateless enum over raw text.
///
/// A file with no markers at all parses to a single `.context` segment (or none, if empty) — the
/// caller doesn't need to special-case "not actually conflicted".
public enum ConflictParser {
    public static func parse(_ text: String) -> [ConflictSegment] {
        var segments: [ConflictSegment] = []
        var contextBuffer: [String] = []
        var oursLabel = ""
        var oursLines: [String] = []
        var theirsLines: [String] = []
        var inOurs = false
        var inBase = false
        var inTheirs = false

        func flushContext() {
            if !contextBuffer.isEmpty {
                segments.append(.context(lines: contextBuffer))
                contextBuffer = []
            }
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() } // trailing newline produces one empty element

        for line in lines {
            if line.hasPrefix("<<<<<<<") {
                flushContext()
                oursLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                oursLines = []
                inOurs = true
                inBase = false
            } else if line.hasPrefix("|||||||"), inOurs {
                inOurs = false
                inBase = true
            } else if line.hasPrefix("======="), inOurs || inBase {
                inOurs = false
                inBase = false
                inTheirs = true
                theirsLines = []
            } else if line.hasPrefix(">>>>>>>"), inTheirs {
                let theirsLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                segments.append(.conflict(ours: ConflictSide(label: oursLabel, lines: oursLines),
                                           theirs: ConflictSide(label: theirsLabel, lines: theirsLines)))
                inTheirs = false
            } else if inOurs {
                oursLines.append(line)
            } else if inBase {
                // Common-ancestor text (diff3/zdiff3): deliberately dropped, not folded into
                // either side — see the doc comment on `ConflictSegment`.
            } else if inTheirs {
                theirsLines.append(line)
            } else {
                contextBuffer.append(line)
            }
        }
        flushContext()
        return segments
    }
}
