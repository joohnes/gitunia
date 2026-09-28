import Foundation

/// Subsequence fuzzy matching for the command palette (repo names, action labels).
public enum FuzzyMatch {
    /// nil when `query` is not a case-insensitive subsequence of `candidate`.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let q = Array(query.lowercased())
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

    /// Drops non-matches, sorts by score descending; equal scores keep original order.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            guard let s = score(query, key(item)) else { return nil }
            return (s, index, item)
        }
        return scored
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }
}
