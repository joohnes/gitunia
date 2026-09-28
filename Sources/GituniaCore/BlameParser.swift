import Foundation

/// One line of `git blame --porcelain -- <path>` output, resolved against the working-tree file.
/// `lineNumber` is 1-based, matching the file's own line numbering (porcelain's "final" line
/// number — the third field of the header line).
public struct BlameLine: Identifiable, Hashable, Sendable {
    public let lineNumber: Int
    public let text: String
    public let commitHash: String
    public let author: String
    /// Unix timestamp (`author-time`), seconds since epoch.
    public let authorTime: TimeInterval
    public let summary: String
    /// This file's path *at that commit* (porcelain's `filename` field) — differs from the
    /// working-tree path for a line last touched before a rename.
    public let filename: String
    public var id: Int { lineNumber }

    /// Real git (verified in a temp repo) marks an uncommitted line with the all-zero hash and
    /// `author`/`committer` literally "Not Committed Yet" — this checks the hash, which is the
    /// stable signal (the author string is just conventional text, not a format guarantee).
    public var isUncommitted: Bool { commitHash == BlamePorcelainParser.uncommittedHash }

    public init(lineNumber: Int, text: String, commitHash: String, author: String, authorTime: TimeInterval, summary: String, filename: String) {
        self.lineNumber = lineNumber; self.text = text; self.commitHash = commitHash
        self.author = author; self.authorTime = authorTime; self.summary = summary; self.filename = filename
    }
}

/// Parses `git blame --porcelain -- <path>`. Verified against real git (2.51) output in a temp
/// repo with two authors and an uncommitted edit:
///
/// ```
/// 2a93679... 1 1 1
/// author Alice A
/// author-mail <a@example.com>
/// author-time 1790174101
/// ...
/// summary first commit
/// filename f.txt
/// \tline one
/// f318438... 2 2 1
/// author Bob B
/// ...
/// \tline two changed
/// 2a93679... 3 3 1
/// \tline three
/// ```
///
/// Every line gets its own header (`<sha> <origline> <finalline> [<count>]`), but the metadata
/// lines (`author`, `author-time`, `summary`, `filename`, …) are only emitted the *first* time a
/// given hash appears anywhere in the output — a repeated hash (line 3 above, `2a93679`'s second
/// appearance) is just the header immediately followed by the tab-indented content line, so this
/// parser caches metadata per hash and carries it forward. An uncommitted line's hash is
/// `0000000000000000000000000000000000000000`, with `author`/`committer` literally
/// "Not Committed Yet".
public enum BlamePorcelainParser {
    public static let uncommittedHash = String(repeating: "0", count: 40)

    private struct Meta { var author = ""; var authorTime: TimeInterval = 0; var summary = ""; var filename = "" }

    public static func parse(_ text: String) -> [BlameLine] {
        var metaByHash: [String: Meta] = [:]
        var result: [BlameLine] = []
        var currentHash = ""
        var currentFinalLine = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Content line: exactly one tab, then the file's line verbatim (leading spaces/tabs in
            // the file's own content are preserved — only this one separator tab is stripped).
            if raw.hasPrefix("\t") {
                guard !currentHash.isEmpty else { continue }
                let meta = metaByHash[currentHash] ?? Meta()
                result.append(BlameLine(
                    lineNumber: currentFinalLine, text: String(raw.dropFirst()), commitHash: currentHash,
                    author: meta.author, authorTime: meta.authorTime, summary: meta.summary, filename: meta.filename
                ))
                continue
            }
            // Header line: "<40-hex-sha> <origline> <finalline>[ <count>]".
            let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, fields[0].count == 40, fields[0].allSatisfy(\.isHexDigit), let final = Int(fields[2]) {
                currentHash = String(fields[0])
                currentFinalLine = final
                if metaByHash[currentHash] == nil { metaByHash[currentHash] = Meta() }
                continue
            }
            // Metadata line for the hash currently being described.
            guard !currentHash.isEmpty else { continue }
            var meta = metaByHash[currentHash] ?? Meta()
            if let v = value(after: "author ", in: raw) { meta.author = v }
            else if let v = value(after: "author-time ", in: raw) { meta.authorTime = TimeInterval(v) ?? 0 }
            else if let v = value(after: "summary ", in: raw) { meta.summary = v }
            else if let v = value(after: "filename ", in: raw) { meta.filename = v }
            metaByHash[currentHash] = meta
        }
        return result
    }

    private static func value(after prefix: String, in line: Substring) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}

/// Where `BlameBodyView`'s gutter shows an annotation: the first line of each run of consecutive
/// lines from the same commit gets hash/author/date, later lines in the run stay blank but share
/// the run's `band` so the view can still paint a continuous background across it. Pure and
/// tested independently of any git call or SwiftUI.
public struct BlameRowInfo: Equatable, Sendable {
    public let isRunStart: Bool
    public let band: Int
}

public enum BlameGrouping {
    public static func rows(for lines: [BlameLine]) -> [BlameRowInfo] {
        var result: [BlameRowInfo] = []
        var previousHash: String?
        var band = -1
        for line in lines {
            let isStart = line.commitHash != previousHash
            if isStart { band += 1 }
            result.append(BlameRowInfo(isRunStart: isStart, band: band))
            previousHash = line.commitHash
        }
        return result
    }
}

/// What `RepositoryStore.blame(path:)` returns: the (possibly capped) lines plus whether the file
/// was actually longer than the cap.
public struct BlameResult: Equatable, Sendable {
    public let lines: [BlameLine]
    public let truncated: Bool
    public let totalLines: Int

    public init(lines: [BlameLine], truncated: Bool, totalLines: Int) {
        self.lines = lines; self.truncated = truncated; self.totalLines = totalLines
    }
}

/// Caps how many lines a blame view will ever render — a 20k-line file's blame is still cheap for
/// git to produce, but rendering that many annotated rows in one `LazyVStack` is not something to
/// do unconditionally. Pure, so the cap behavior is testable without a huge fixture file.
public enum BlameCap {
    public static let maxLines = 20_000

    public static func apply(_ lines: [BlameLine]) -> BlameResult {
        guard lines.count > maxLines else { return BlameResult(lines: lines, truncated: false, totalLines: lines.count) }
        return BlameResult(lines: Array(lines.prefix(maxLines)), truncated: true, totalLines: lines.count)
    }
}
