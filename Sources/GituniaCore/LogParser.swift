import Foundation

/// Parses `git log --pretty=format:<format> --date=short`. `%P` (space-separated parent hashes,
/// possibly empty for a root commit) is only used for its count — see `CommitInfo.parentCount`.
/// The trailing `%ae` field is optional (6-field records leave `CommitInfo.authorEmail` empty).
public enum LogParser {
    /// One commit's fields, without a record separator (`FileHistoryParser` puts `%x1e` in front).
    public static let fields = "%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1f%ae"
    /// Pass as `--pretty=format:\(LogParser.format)` together with `--date=short`.
    public static let format = fields + "%x1e"

    public static func parse(_ text: String) -> [CommitInfo] {
        text.split(separator: "\u{1e}").compactMap {
            commit(fields: $0.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init))
        }
    }

    /// 6 or 7 fields in `fields` order → `CommitInfo`; anything else is nil.
    static func commit(fields f: [String]) -> CommitInfo? {
        guard f.count == 6 || f.count == 7 else { return nil }
        let parentCount = f[5].split(separator: " ", omittingEmptySubsequences: true).count
        return CommitInfo(hash: f[0], shortHash: f[1], author: f[2], date: f[3], subject: f[4], parentCount: parentCount,
                          authorEmail: f.count == 7 ? f[6] : "")
    }
}
