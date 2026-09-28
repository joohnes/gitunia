import Foundation

/// Posting text (the Activity report) to GitHub through `gh` — no auth of Gitunia's own. Every
/// call is an outward-facing write; the UI confirms before calling.
extension RepositoryStore {
    /// gh installed and `origin` on github.com (checks the remote once, unlike `pullRequestsSupported`).
    public func supportsGitHubPost() async -> Bool {
        gh.isAvailable ? await checkGitHubRemote() : false
    }

    /// `owner/repo` of origin, for the confirmation text; nil when origin isn't on github.com.
    public func gitHubSlug() async -> String? {
        guard let pull = GitHubURL.pull(remoteURL: await originURL(), number: 0) else { return nil }
        return pull.pathComponents.dropFirst().prefix(2).joined(separator: "/")
    }

    /// `gh pr comment <n> --body-file <tmp>` → the comment's URL.
    public func postPullRequestComment(number: Int, body: String) async -> Result<URL, GHError> {
        await postWithBodyFile(body) { ["pr", "comment", String(number), "--body-file", $0] }
    }

    /// `gh issue create --title … --body-file <tmp> [--label …]` → the issue's URL.
    public func createIssue(title: String, body: String, labels: [String]) async -> Result<URL, GHError> {
        await postWithBodyFile(body) { file in
            ["issue", "create", "--title", title, "--body-file", file] + labels.flatMap { ["--label", $0] }
        }
    }

    /// Open PRs for the "PR comment" picker; empty when gh is missing, origin isn't GitHub, or gh fails.
    public func openPullRequests() async -> [PullRequest] {
        struct Row: Decodable { var number: Int; var title: String; var headRefName: String; var url: String }
        guard await supportsGitHubPost(),
              let out = try? await gh.run(["pr", "list", "--state", "open", "--json", "number,title,headRefName,url",
                                           "--limit", "50"], in: url),
              let rows = try? JSONDecoder().decode([Row].self, from: Data(out.utf8)) else { return [] }
        return rows.map { PullRequest(number: $0.number, title: $0.title, state: "OPEN", url: $0.url, isDraft: false,
                                      headRefName: $0.headRefName, baseRefName: "") }
    }

    private func postWithBodyFile(_ body: String, args: (String) -> [String]) async -> Result<URL, GHError> {
        guard gh.isAvailable else { return .failure(.notInstalled) }
        guard await checkGitHubRemote() else { return .failure(.failed("origin isn't a GitHub remote.")) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-post-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            let out = try await gh.run(args(file.path), in: url)
            let last = out.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard last.hasPrefix("https://"), let result = URL(string: last) else {
                return .failure(.failed("Posted, but gh didn't print a URL: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"))
            }
            return .success(result)
        } catch let error as GHError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
