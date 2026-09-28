import Foundation

/// One step of `git clone --progress` as shown to the user: the phase git is in and, when git
/// reports one, its percentage.
public struct CloneProgress: Equatable, Sendable {
    public var phase: String
    public var percent: Int?
    public init(phase: String, percent: Int? = nil) { self.phase = phase; self.percent = percent }
}

/// Turns raw `git clone --progress` stderr chunks into `CloneProgress`. Verified against real
/// output of a `file://` clone (git 2.50): progress lines are `\r`-terminated and rewrite each
/// other (`Receiving objects:  45% (136/302)\r`), phase-final lines end in `, done.\n`, and
/// server-side phases carry a `remote: ` prefix plus trailing space padding
/// (`remote: Counting objects: 100% (302/302), done.        `). A plain local-path clone prints
/// no progress at all (hardlinks), only `Cloning into 'x'...` and `done.`.
public struct CloneProgressParser: Sendable {
    private var buffer = ""
    public init() {}

    /// Feeds one stderr chunk; returns the newest progress among the lines it completed, if any.
    public mutating func feed(_ chunk: String) -> CloneProgress? {
        buffer += chunk
        var lines = buffer.split(omittingEmptySubsequences: false) { $0 == "\r" || $0 == "\n" }
        buffer = String(lines.removeLast())
        return lines.compactMap(Self.parseLine).last
    }

    public static func parseLine(_ raw: Substring) -> CloneProgress? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("remote: ") { line = String(line.dropFirst("remote: ".count)) }
        if line.hasPrefix("Cloning into ") { return CloneProgress(phase: "Cloning") }
        guard let colon = line.range(of: ": ") else { return nil }
        let phase = String(line[..<colon.lowerBound])
        let rest = line[colon.upperBound...].drop { $0 == " " }
        guard rest.first?.isNumber == true, !["fatal", "error", "warning", "hint"].contains(phase) else { return nil }
        let digits = rest.prefix { $0.isNumber }
        let percent = rest.dropFirst(digits.count).first == "%" ? Int(digits) : nil
        return CloneProgress(phase: phase, percent: percent)
    }
}

/// Extra `git clone` flags for big monorepos. All off by default: a plain full clone.
public struct CloneOptions: Equatable, Sendable {
    /// `--filter=blob:none`: history now, file contents fetched on demand.
    public var partial = false
    /// `--depth 1`.
    public var shallow = false
    /// `--sparse`: check out only the root files; folders are picked afterwards.
    public var sparse = false
    public init(partial: Bool = false, shallow: Bool = false, sparse: Bool = false) {
        self.partial = partial; self.shallow = shallow; self.sparse = sparse
    }

    public var arguments: [String] {
        (partial ? ["--filter=blob:none"] : []) + (shallow ? ["--depth", "1"] : []) + (sparse ? ["--sparse"] : [])
    }
}

public enum RepoURL {
    /// The folder name `git clone` itself would pick: last path component, `.git` stripped.
    /// Handles scp-style `git@host:owner/repo.git` and trailing slashes.
    public static func defaultName(from url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let colon = s.lastIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// Replaces the password part of any `scheme://user:password@` userinfo with `•••` (via `URLRedaction`), so a
    /// token pasted into a clone URL never reaches the screen (git redacts it in some messages
    /// itself, e.g. "unable to access 'https://127.0.0.1:1/x.git/'", but not everywhere).
    public static func redactingCredentials(_ text: String) -> String {
        // One redaction rule for the whole app: `URLRedaction` (Remotes.swift) also hides a bare
        // token used as the http(s) username, which this function's own regex used to miss.
        URLRedaction.redact(text)
    }
}

public enum NewRepoName {
    /// `nil` when `name` is usable as a new top-level folder in `workspace`, otherwise the reason.
    /// Rejects anything `WorkspaceScanner` would never find (hidden, skipped names) so a repo the
    /// user just created can't silently fail to appear in the sidebar.
    public static func validate(_ name: String, in workspace: URL) -> String? {
        if name.isEmpty { return "Enter a folder name." }
        if name.contains("/") || name.contains(":") { return "Use a single folder name, not a path." }
        if name.hasPrefix(".") || name.hasPrefix("-") { return "Folder names can't start with “\(name.first!)”." }
        if WorkspaceScanner.skippedDirectoryNames.contains(name) { return "“\(name)” is skipped by folder scans." }
        if FileManager.default.fileExists(atPath: workspace.appendingPathComponent(name).path) {
            return "“\(name)” already exists in that folder."
        }
        return nil
    }
}
