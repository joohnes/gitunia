import Foundation
import GituniaCore

/// How many commits to (re)fetch when the load context (repo/branch/filter/file-history path) did
/// or didn't change. A real change resets to one page; a same-context rerun (a new commit landed
/// while more pages were loaded) fetches at least as many as were showing, so `loadMore()`'s
/// progress — and the selected commit, if still in range — survives.
enum HistoryPaging {
    static func limit(sameContext: Bool, currentCount: Int, pageSize: Int) -> Int {
        sameContext ? max(currentCount, pageSize) : pageSize
    }
}

/// The history row's date, readable ("3 days ago") with the exact date on hover. Parses
/// `CommitInfo.date`'s `--date=short` form (`"2024-01-15"`) — the only precision `LogParser`
/// gives this list.
@MainActor
enum HistoryRowDate {
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func readable(_ short: String) -> String {
        shortFormatter.date(from: short).map { RelativeDate.string(for: $0) } ?? short
    }

    static func absolute(_ short: String) -> String {
        shortFormatter.date(from: short).map(RelativeDate.absolute) ?? short
    }
}
