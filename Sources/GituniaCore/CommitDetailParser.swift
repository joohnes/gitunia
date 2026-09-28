import Foundation

/// Parses one record of
/// `git show -s --format=%H%x1f%s%x1f%b%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%P%x1f%p%x1e`
/// (`%b` can itself contain newlines — that's fine, only the literal `%x1f`/`%x1e` bytes git
/// inserts are used as separators, same house style as `LogParser`).
public enum CommitDetailParser {
    /// Field order matches the format string above: hash, subject, body, author name/email/date,
    /// committer name/email/date, parents (full), parents (short).
    public static func parse(_ text: String) -> CommitDetail? {
        guard let record = text.split(separator: "\u{1e}", maxSplits: 1).first else { return nil }
        let f = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 11 else { return nil }
        let parents = f[9].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let parentsShort = f[10].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return CommitDetail(
            hash: f[0], subject: f[1], body: f[2].trimmingCharacters(in: .newlines),
            authorName: f[3], authorEmail: f[4], authorDate: f[5],
            committerName: f[6], committerEmail: f[7], committerDate: f[8],
            parents: parents, parentsShort: parentsShort
        )
    }
}
