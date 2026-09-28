import Foundation

public enum BisectVerdict: String, Sendable, CaseIterable {
    case good, bad, skip
}

/// What `git bisect log` (plus the last bisect command's stdout) says about a running bisect.
public struct BisectState: Sendable, Equatable {
    public var good: [String] = []
    public var bad: [String] = []
    public var skipped: [String] = []
    /// The commit git checked out for testing — from the last output's `[<hash>] subject` line.
    public var current: String?
    public var isActive = false
    /// K from "Bisecting: N revisions left to test after this (roughly K steps)".
    public var remainingSteps: Int?
    /// From "<hash> is the first bad commit" (output) or "# first bad commit: [<hash>]" (log).
    /// git 2.55+ quotes the term ("first 'bad' commit"); a custom `--term-bad` replaces it.
    public var firstBad: String?

    public init(good: [String] = [], bad: [String] = [], skipped: [String] = [], current: String? = nil,
                isActive: Bool = false, remainingSteps: Int? = nil, firstBad: String? = nil) {
        self.good = good; self.bad = bad; self.skipped = skipped; self.current = current
        self.isActive = isActive; self.remainingSteps = remainingSteps; self.firstBad = firstBad
    }

    public func verdict(for hash: String) -> BisectVerdict? {
        if bad.contains(hash) { return .bad }
        if good.contains(hash) { return .good }
        if skipped.contains(hash) { return .skip }
        return nil
    }
}

public enum BisectLog {
    /// The log's `# good: [<hash>] subject` comment lines carry resolved hashes (the
    /// `git bisect start 'HEAD' 'HEAD~5'` command lines don't), so only those are read.
    public static func parse(log: String, lastOutput: String = "") -> BisectState {
        var state = BisectState()
        for line in log.split(separator: "\n") {
            guard line.hasPrefix("# "), let hash = bracketed(line) else { continue }
            if line.hasPrefix("# good:") { state.good.append(hash) }
            else if line.hasPrefix("# bad:") { state.bad.append(hash) }
            else if line.hasPrefix("# skip:") { state.skipped.append(hash) }
            else if line.hasPrefix("# first "), line.contains(" commit: [") { state.firstBad = hash }
        }
        state.isActive = !log.isEmpty
        for line in lastOutput.split(separator: "\n") {
            if line.hasPrefix("Bisecting:"), let r = line.range(of: "(roughly ") {
                state.remainingSteps = Int(line[r.upperBound...].prefix(while: \.isNumber))
            } else if line.hasPrefix("["), state.current == nil {
                state.current = bracketed(line)
            } else if line.contains(" is the first "), line.hasSuffix(" commit") {
                state.firstBad = String(line.prefix(while: { !$0.isWhitespace }))
            }
        }
        if state.firstBad != nil { state.current = nil; state.remainingSteps = nil }
        return state
    }

    private static func bracketed(_ line: Substring) -> String? {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}
