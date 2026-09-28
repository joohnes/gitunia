import Foundation

/// The one relative-date rule for the app (blame, stashes, reflog, commit detail): anything within
/// the last minute — or stamped in the future by clock skew — reads "just now", never "in 0s" or
/// "0 seconds ago"; older dates use the system's abbreviated relative phrasing ("3 days ago").
@MainActor
public enum RelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    public static func string(for date: Date, relativeTo now: Date = Date()) -> String {
        if date.timeIntervalSince(now) > -60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The absolute form shown on hover next to a relative date.
    public static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `--date=iso-strict` output (`2026-09-23T15:59:48+02:00`) → Date.
    public static func parseISO(_ text: String) -> Date? {
        try? Date(text.trimmingCharacters(in: .whitespaces), strategy: .iso8601)
    }
}
