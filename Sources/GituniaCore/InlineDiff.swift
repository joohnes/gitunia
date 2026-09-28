import Foundation

/// Word-level intra-line diffing: given a removed line and the added line that replaced it,
/// finds which parts actually differ so the view can highlight just those instead of tinting
/// the whole line. Tokenizes on word boundaries and runs an LCS over tokens rather than
/// characters — a character-level LCS over source code produces unreadable speckle (two lines
/// differing by one identifier light up in a dozen fragments).
public enum InlineDiff {
    /// Below this fraction of shared tokens (relative to the longer side), the two lines are
    /// considered unrelated rewrites rather than edits of each other. Token-level highlighting
    /// at that point is mostly confetti — matching stray punctuation and keywords — so whole-line
    /// highlighting (today's behavior) reads better.
    static let dissimilarityThreshold = 0.25

    /// Above this many tokens on either side, skip the LCS (its DP table is O(n·m)) and fall
    /// back to full-range highlighting. A few thousand tokens is far beyond any real code line;
    /// this exists to keep a 200KB minified-JS line from hanging the UI.
    static let tokenCountCap = 2000

    /// A removed/added line pair: indices into the hunk's `lines` array.
    public struct LinePair: Sendable, Equatable {
        public let removedIndex: Int
        public let addedIndex: Int
        public init(removedIndex: Int, addedIndex: Int) {
            self.removedIndex = removedIndex
            self.addedIndex = addedIndex
        }
    }

    /// Within a hunk, pairs each maximal run of removed lines with the run of added lines that
    /// immediately follows it, index by index. Unequal run lengths leave the surplus unpaired.
    /// A removed run not immediately followed by an added run (context or end of hunk) pairs
    /// with nothing, and likewise for an added run not immediately preceded by a removed run.
    public static func pairs(in lines: [DiffLine]) -> [LinePair] {
        let runs = DiffLine.runs(lines, by: \.kind)
        var result: [LinePair] = []
        for k in 0..<runs.count {
            guard runs[k].key == .removed, k + 1 < runs.count, runs[k + 1].key == .added else { continue }
            let removedRange = runs[k].range
            let addedRange = runs[k + 1].range
            let count = min(removedRange.count, addedRange.count)
            for offset in 0..<count {
                result.append(LinePair(removedIndex: removedRange.lowerBound + offset, addedIndex: addedRange.lowerBound + offset))
            }
        }
        return result
    }

    /// The result of comparing a removed/added line pair. `didFallBack` is true when the two
    /// lines were too dissimilar (or one side was empty) for token-level highlighting to be
    /// useful, in which case `removed`/`added` are each the line's full range rather than a set
    /// of sub-ranges — callers that want to skip whole-line emphasis in that case should check
    /// this flag directly rather than inferring it from the ranges' shape.
    public struct WordRanges: Sendable, Equatable {
        public let removed: [Range<String.Index>]
        public let added: [Range<String.Index>]
        public let didFallBack: Bool
        public init(removed: [Range<String.Index>], added: [Range<String.Index>], didFallBack: Bool) {
            self.removed = removed
            self.added = added
            self.didFallBack = didFallBack
        }
    }

    /// Returns the ranges in `removed` and `added` that differ from each other.
    public static func wordRanges(removed: String, added: String) -> WordRanges {
        let fullRanges = WordRanges(
            removed: removed.isEmpty ? [] : [removed.startIndex..<removed.endIndex],
            added: added.isEmpty ? [] : [added.startIndex..<added.endIndex],
            didFallBack: true
        )
        guard !removed.isEmpty, !added.isEmpty else { return fullRanges }

        let removedTokens = tokenize(removed)
        let addedTokens = tokenize(added)
        guard removedTokens.count <= tokenCountCap, addedTokens.count <= tokenCountCap else { return fullRanges }

        let removedStrings = removedTokens.map { String(removed[$0]) }
        let addedStrings = addedTokens.map { String(added[$0]) }
        let (removedMatched, addedMatched, commonCount) = lcsMatchedIndices(removedStrings, addedStrings)

        let longerCount = max(removedTokens.count, addedTokens.count)
        if longerCount == 0 || Double(commonCount) / Double(longerCount) < dissimilarityThreshold {
            return fullRanges
        }

        return WordRanges(
            removed: mergedRanges(tokens: removedTokens, matched: removedMatched),
            added: mergedRanges(tokens: addedTokens, matched: addedMatched),
            didFallBack: false
        )
    }

    /// Splits `text` into tokens: a run of identifier characters (letters, digits, `_`), a run
    /// of whitespace, or a single punctuation/symbol character.
    private static func tokenize(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if isWord(c) {
                var j = text.index(after: i)
                while j < text.endIndex, isWord(text[j]) { j = text.index(after: j) }
                ranges.append(i..<j)
                i = j
            } else if c.isWhitespace {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                ranges.append(i..<j)
                i = j
            } else {
                let j = text.index(after: i)
                ranges.append(i..<j)
                i = j
            }
        }
        return ranges
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// Standard O(n·m) LCS over token strings, backtracked into the set of matched token
    /// indices on each side. Returns those two index sets plus the LCS length.
    private static func lcsMatchedIndices(_ a: [String], _ b: [String]) -> (Set<Int>, Set<Int>, Int) {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return ([], [], 0) }

        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }

        var removedMatched = Set<Int>()
        var addedMatched = Set<Int>()
        var i = n, j = m
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                removedMatched.insert(i - 1)
                addedMatched.insert(j - 1)
                i -= 1; j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (removedMatched, addedMatched, Int(table[n][m]))
    }

    /// Ranges for tokens *not* in the matched set, with adjacent unmatched tokens merged into
    /// one range (they are already contiguous in the source string) so the view draws a single
    /// highlight instead of several.
    private static func mergedRanges(tokens: [Range<String.Index>], matched: Set<Int>) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var runStart: String.Index?
        var runEnd: String.Index?
        for (idx, range) in tokens.enumerated() {
            if matched.contains(idx) {
                if let start = runStart, let end = runEnd { result.append(start..<end) }
                runStart = nil; runEnd = nil
            } else {
                if runStart == nil { runStart = range.lowerBound }
                runEnd = range.upperBound
            }
        }
        if let start = runStart, let end = runEnd { result.append(start..<end) }
        return result
    }
}
