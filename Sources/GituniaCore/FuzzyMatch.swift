import Foundation

/// Subsequence fuzzy matching for the command palette (repo names, action labels).
public enum FuzzyMatch {
    /// nil when `query` is not a case-insensitive subsequence of `candidate`.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        return score(Query(query), candidate)
    }

    /// The query lowercased once — `rank` builds this once instead of per candidate.
    private struct Query {
        let chars: [Character]
        /// The same characters as bytes, when they're all ASCII (nil otherwise).
        let ascii: [UInt8]?
        init(_ query: String) {
            chars = Array(query.lowercased())
            let bytes = chars.compactMap(\.asciiValue)
            ascii = bytes.count == chars.count ? bytes : nil
        }
    }

    private static func score(_ query: Query, _ candidate: String) -> Int? {
        if let ascii = query.ascii, !mayMatch(ascii, candidate) { return nil }
        let q = query.chars

        let c = Array(candidate)
        let cLower = Array(candidate.lowercased())

        var qi = 0
        var score = 0
        var runLength = 0
        var lastMatch = -1

        for ci in 0..<c.count where qi < q.count {
            guard cLower[ci] == q[qi] else { continue }

            var gained = 10
            let boundary = ci == 0
                || c[ci - 1] == "/" || c[ci - 1] == "-" || c[ci - 1] == "_"
                || c[ci - 1] == "." || c[ci - 1] == " "
                || (c[ci - 1].isLowercase && c[ci].isUppercase)
            if boundary { gained += 8 }

            if lastMatch == ci - 1 {
                runLength += 1
                gained += runLength * 4 // reward consecutive runs
            } else {
                runLength = 0
                if lastMatch >= 0 { gained -= min(ci - lastMatch, 5) } // penalise gaps
            }

            score += gained
            lastMatch = ci
            qi += 1
        }

        guard qi == q.count else { return nil }

        if cLower.starts(with: q) { score += 20 } // full prefix match
        score -= c.count / 4 // penalise long candidates

        return score
    }

    /// Allocation-free subsequence pre-check, so most non-matches among thousands of branch names
    /// never pay for the three arrays above. Only decides for all-ASCII input, where byte equality
    /// after ASCII lowercasing is exactly `Character` equality after `lowercased()`; anything else
    /// answers "maybe" and the full scorer decides — so results are identical either way.
    private static func mayMatch(_ q: [UInt8], _ candidate: String) -> Bool {
        var qi = 0
        for byte in candidate.utf8 {
            guard byte < 0x80 else { return true }
            let lower = byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
            if qi < q.count, lower == q[qi] { qi += 1 }
        }
        return qi == q.count
    }

    /// Drops non-matches, sorts by score descending; equal scores keep original order. An empty
    /// query matches everything with the same score, so `items` comes back unchanged.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        if query.isEmpty { return items }
        let q = Query(query)
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            guard let s = score(q, key(item)) else { return nil }
            return (s, index, item)
        }
        return scored
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }
}
