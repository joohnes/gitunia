import Foundation

/// One GitHub release, as `UpdateCoordinator` and Settings → Updates need it. `version` has any
/// leading "v" stripped from the tag, so it compares directly against `CFBundleShortVersionString`.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public let tag: String
    public let version: String
    public let htmlURL: URL
    public let dmgURL: URL?
    /// `<dmg name>.sig`: base64 Curve25519 signature over the dmg bytes (see `UpdateInstaller`).
    public let signatureURL: URL?
    public let notes: String?
    public let publishedAt: Date?

    public init(tag: String, version: String, htmlURL: URL, dmgURL: URL?, signatureURL: URL? = nil, notes: String?, publishedAt: Date?) {
        self.tag = tag
        self.version = version
        self.htmlURL = htmlURL
        self.dmgURL = dmgURL
        self.signatureURL = signatureURL
        self.notes = notes
        self.publishedAt = publishedAt
    }
}

/// Checks GitHub Releases for a newer Gitunia build. It only reports what's there;
/// `UpdateCoordinator` decides whether to auto-install it (`UpdateInstaller`) or offer the download.
public final class UpdateChecker: Sendable {
    private let repo: String
    private let fetch: @Sendable (URL) async throws -> Data

    public init(repo: String = "joohnes/gitunia", fetch: @escaping @Sendable (URL) async throws -> Data = UpdateChecker.defaultFetch) {
        self.repo = repo
        self.fetch = fetch
    }

    /// GET `releases/latest`; never throws — a network/parse failure just means "no update known
    /// this time", not an error the caller has to handle.
    public func latest() async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              let data = try? await fetch(url) else { return nil }
        return Self.parse(data)
    }

    public static let defaultFetch: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        request.setValue("Gitunia/\(version)", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request).0
    }

    private struct GHAsset: Decodable { var browser_download_url: String }
    private struct GHRelease: Decodable {
        var tag_name: String
        var html_url: String
        var body: String?
        var published_at: String?
        var draft: Bool = false
        var prerelease: Bool = false
        var assets: [GHAsset] = []
    }

    /// Parses the `releases/latest` JSON GitHub returns. `nil` for a draft/prerelease or anything
    /// unparseable — the fixed set of fields Gitunia actually needs, tolerant of everything else.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let rel = try? JSONDecoder().decode(GHRelease.self, from: data),
              !rel.draft, !rel.prerelease,
              let htmlURL = URL(string: rel.html_url) else { return nil }
        let version = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
        let assets = rel.assets.map(\.browser_download_url)
        let dmg = assets.first { $0.hasSuffix(".dmg") }
        let dmgURL = dmg.flatMap(URL.init(string:))
        let signatureURL = dmg.flatMap { dmg in assets.first { $0 == dmg + ".sig" } }.flatMap(URL.init(string:))
        let publishedAt = rel.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(tag: rel.tag_name, version: version, htmlURL: htmlURL, dmgURL: dmgURL, signatureURL: signatureURL, notes: rel.body, publishedAt: publishedAt)
    }

    /// Numeric dotted compare, tolerant of a leading "v" and mismatched component counts (missing
    /// components read as 0, so "0.1.0" == "0.1"). Unparseable components read as 0 too, so garbage
    /// input compares equal rather than throwing — callers just get `false`.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote), l = components(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0, lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        var s = Substring(version)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return s.split(separator: ".").map { Int($0) ?? 0 }
    }
}
