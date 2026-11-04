import Foundation

/// The "All changes" review's filter: which files from every repository's working tree are shown.
/// Pure value logic (no store, no SwiftUI) so the rules are unit-tested and the view only renders.
public struct ChangeFilter: Equatable, Sendable {
    /// Where a change sits — one per file row, matching the Changes list's sections.
    public enum Kind: String, CaseIterable, Sendable {
        case staged, unstaged, untracked, conflicted
        public var label: String {
            switch self {
            case .staged: "Staged"
            case .unstaged: "Unstaged"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }
    }

    /// Space-separated terms, all of which must appear in the path (case-insensitive);
    /// a term starting with `!` must not. `".swift !Tests"` = Swift files outside Tests.
    public var query: String
    public var kinds: Set<Kind>
    /// Hides lockfiles, minified bundles, source maps, snapshots and other generated files.
    public var hideNoise: Bool

    public init(query: String = "", kinds: Set<Kind> = Set(Kind.allCases), hideNoise: Bool = true) {
        self.query = query
        self.kinds = kinds
        self.hideNoise = hideNoise
    }

    public var isDefault: Bool { self == ChangeFilter() }

    public static func kind(of change: FileChange) -> Kind {
        if change.status == .conflicted { return .conflicted }
        if change.status == .untracked { return .untracked }
        return change.area == .staged ? .staged : .unstaged
    }

    public func matches(_ change: FileChange) -> Bool {
        guard kinds.contains(Self.kind(of: change)) else { return false }
        // A conflict always needs a decision, so it is never hidden as noise.
        if hideNoise, change.status != .conflicted, Self.isNoise(change.path) { return false }
        return Self.matches(query: query, path: change.path) || (change.oldPath.map { Self.matches(query: query, path: $0) } ?? false)
    }

    /// The changes to show and how many the filter hid.
    public func apply(_ changes: [FileChange]) -> (shown: [FileChange], hidden: Int) {
        let shown = changes.filter(matches)
        return (shown, changes.count - shown.count)
    }

    static func matches(query: String, path: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = path.lowercased()
        for term in terms {
            let lowered = term.lowercased()
            if lowered.hasPrefix("!") {
                let excluded = lowered.dropFirst()
                if !excluded.isEmpty, haystack.contains(excluded) { return false }
            } else if !haystack.contains(lowered) {
                return false
            }
        }
        return true
    }

    private static let noiseSuffixes = [
        ".min.js", ".min.css", ".map", ".snap", ".pb.go", ".pb.swift", "_pb2.py", ".g.dart", ".freezed.dart",
        ".generated.swift", ".generated.ts", ".designer.cs", ".xcuserstate",
    ]
    private static let noiseNames: Set<String> = [".DS_Store", "npm-shrinkwrap.json"]
    private static let noiseDirectories = ["node_modules/", "__snapshots__/", "xcuserdata/", ".build/", "DerivedData/"]

    /// Files a reviewer rarely reads line by line: dependency lockfiles, build output that got
    /// committed, generated code. Conservative on purpose — a hidden file is still counted and one
    /// toggle away, but a real source file must never land here.
    public static func isNoise(_ path: String) -> Bool {
        if ChangeClassification.isLockfile(path) { return true }
        let name = (path as NSString).lastPathComponent
        if noiseNames.contains(name) { return true }
        let lowered = name.lowercased()
        if noiseSuffixes.contains(where: { lowered.hasSuffix($0) }) { return true }
        let wrapped = "/" + path
        return noiseDirectories.contains { wrapped.contains("/" + $0) }
    }
}
