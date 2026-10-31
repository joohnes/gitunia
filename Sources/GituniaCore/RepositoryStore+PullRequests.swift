import Foundation

/// `gh pr view --json` for one pull request. `statusCheckRollup` mixes two GraphQL shapes:
/// `CheckRun` (`name`, `status`, `conclusion`) and `StatusContext` (`context`, `state`).
public struct PullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    /// `OPEN` / `MERGED` / `CLOSED`.
    public var state: String
    public var url: String
    public var isDraft: Bool
    public var headRefName: String
    public var baseRefName: String
    /// `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED`, or `""`/nil when the repo has no review rules.
    public var reviewDecision: String?
    public var statusCheckRollup: [Check]?

    static let jsonFields = "number,title,state,url,isDraft,headRefName,baseRefName,reviewDecision,statusCheckRollup"

    public struct Check: Codable, Equatable, Sendable {
        public enum Outcome: Sendable { case passing, failing, pending, neutral }

        public var typename: String?
        public var name: String?
        public var context: String?
        public var status: String?
        public var conclusion: String?
        public var state: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", name, context, status, conclusion, state
        }

        public init(typename: String? = nil, name: String? = nil, context: String? = nil,
                    status: String? = nil, conclusion: String? = nil, state: String? = nil) {
            self.typename = typename; self.name = name; self.context = context
            self.status = status; self.conclusion = conclusion; self.state = state
        }

        public var displayName: String { name ?? context ?? "check" }

        /// The raw result word as GitHub reports it (conclusion for a CheckRun, state for a StatusContext).
        public var result: String {
            if let status, status != "COMPLETED" { return status }
            return [conclusion, state].compactMap { $0 }.first { !$0.isEmpty } ?? "PENDING"
        }

        public var outcome: Outcome {
            switch result {
            case "SUCCESS": return .passing
            case "NEUTRAL", "SKIPPED": return .neutral
            case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": return .failing
            default: return .pending // PENDING, EXPECTED, QUEUED, IN_PROGRESS, WAITING…
            }
        }
    }

    public init(number: Int, title: String, state: String, url: String, isDraft: Bool, headRefName: String,
                baseRefName: String, reviewDecision: String? = nil, statusCheckRollup: [Check]? = nil) {
        self.number = number; self.title = title; self.state = state; self.url = url; self.isDraft = isDraft
        self.headRefName = headRefName; self.baseRefName = baseRefName
        self.reviewDecision = reviewDecision; self.statusCheckRollup = statusCheckRollup
    }

    /// Worst outcome across all checks — nil when there are none.
    public var checksOutcome: Check.Outcome? {
        let outcomes = (statusCheckRollup ?? []).map(\.outcome)
        if outcomes.isEmpty { return nil }
        if outcomes.contains(.failing) { return .failing }
        if outcomes.contains(.pending) { return .pending }
        return outcomes.contains(.passing) ? .passing : .neutral
    }
}

/// Pull-request awareness through the `gh` CLI. Refreshed on repo selection, after a push and when
/// the popover opens — never from `refreshStatus()` (FSEvents ticks), since each call is a network
/// round trip.
extension RepositoryStore {
    /// gh + github.com origin, or az + Azure DevOps origin — the toolbar item's visibility.
    public var pullRequestsSupported: Bool {
        (gh.isAvailable && hasGitHubRemote == true) || (az.isAvailable && hasAzureRemote == true)
    }

    /// `pullRequest`, but only while it still belongs to the checked-out branch (it's not refreshed
    /// on checkout, so a stale one from the previous branch is hidden rather than shown wrong).
    public var currentPullRequest: PullRequest? {
        guard let pr = pullRequest, pr.headRefName == repo.branch else { return nil }
        return pr
    }

    /// One `git remote get-url origin`, cached per store.
    func checkGitHubRemote() async -> Bool {
        if let hasGitHubRemote { return hasGitHubRemote }
        hasGitHubRemote = await originURL().contains("github.com")
        return hasGitHubRemote ?? false
    }

    /// Same as `checkGitHubRemote`, for dev.azure.com / legacy `<org>.visualstudio.com` (https and ssh).
    func checkAzureRemote() async -> Bool {
        if let hasAzureRemote { return hasAzureRemote }
        let origin = await originURL()
        hasAzureRemote = origin.contains("dev.azure.com") || origin.contains("visualstudio.com")
        return hasAzureRemote ?? false
    }

    /// `git remote get-url origin`; empty when there's no origin.
    func originURL() async -> String {
        (try? await git.run(["remote", "get-url", "origin"], in: url, allowedExitCodes: [0, 2, 128])) ?? ""
    }

    /// Re-reads the current branch's pull request into `pullRequest`. nil when there is none, gh is
    /// missing, origin isn't GitHub, or gh failed (then `lastGHError` says why).
    @discardableResult
    public func refreshPullRequest() async -> PullRequest? {
        guard let branch = repo.branch else {
            pullRequest = nil
            return nil
        }
        if gh.isAvailable, await checkGitHubRemote() {
            pullRequest = await pullRequestForCurrentBranch()
        } else if az.isAvailable, await checkAzureRemote() {
            pullRequest = await azurePullRequest(for: branch)
        } else {
            pullRequest = nil
        }
        return pullRequest
    }

    func pullRequestForCurrentBranch() async -> PullRequest? {
        do {
            let out = try await gh.run(["pr", "view", "--json", PullRequest.jsonFields], in: url)
            lastGHError = nil
            return try JSONDecoder().decode(PullRequest.self, from: Data(out.utf8))
        } catch GHError.failed(let message) where message.contains("no pull requests found") {
            lastGHError = nil
            return nil
        } catch {
            lastGHError = (error as? LocalizedError)?.errorDescription ?? "gh: \(error)"
            return nil
        }
    }

    public func createPullRequest(title: String, body: String, draft: Bool, base: String?) async -> Result<PullRequest, GHError> {
        guard let branch = repo.branch else { return .failure(.failed("HEAD is detached — check out a branch first.")) }
        if !(gh.isAvailable && hasGitHubRemote == true), az.isAvailable, await checkAzureRemote() {
            return await createAzurePullRequest(title: title, body: body, draft: draft, base: base, branch: branch)
        }
        var args = ["pr", "create", "--title", title, "--body", body]
        if draft { args.append("--draft") }
        if let base, !base.isEmpty { args += ["--base", base] }
        args += ["--head", branch]
        do {
            _ = try await gh.run(args, in: url)
        } catch let error as GHError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        guard let pr = await refreshPullRequest() else {
            return .failure(.failed(lastGHError ?? "Created, but gh couldn't read the pull request back."))
        }
        return .success(pr)
    }

    /// Prefill for the create form: last commit subject as title; body = the commits since `base`
    /// when there are several, else the last commit's body.
    public func pullRequestDraft(base: String?) async -> (title: String, body: String) {
        let title = ((try? await git.run(["log", "-1", "--format=%s"], in: url)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let base, !base.isEmpty,
           let log = try? await git.run(["log", "--format=- %s", "--max-count=50", "\(base)..HEAD"], in: url),
           log.split(separator: "\n").count > 1 {
            return (title, log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let body = ((try? await git.run(["log", "-1", "--format=%b"], in: url)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }
}

// MARK: - Azure DevOps

/// One pull request as `az repos pr list/create --output json` returns it — only what maps onto `PullRequest`.
struct AzurePullRequest: Decodable {
    var pullRequestId: Int
    var title: String
    /// `active` / `completed` / `abandoned`.
    var status: String
    var isDraft: Bool?
    var sourceRefName: String
    var targetRefName: String
    var repository: Repository
    var reviewers: [Reviewer]?
    struct Repository: Decodable { var webUrl: String }
    /// `vote`: 10 approved, 5 approved with suggestions, 0 none, -5 waiting for author, -10 rejected.
    struct Reviewer: Decodable { var vote: Int; var isRequired: Bool? }

    /// GitHub's words for the votes: any reject/wait → changes requested; every required reviewer
    /// (or, with none required, someone) approving → approved; reviewers but no verdict → required.
    var reviewDecision: String? {
        let reviewers = reviewers ?? []
        if reviewers.isEmpty { return nil }
        if reviewers.contains(where: { $0.vote < 0 }) { return "CHANGES_REQUESTED" }
        let required = reviewers.filter { $0.isRequired == true }
        let approved = required.isEmpty ? reviewers.contains { $0.vote >= 5 } : required.allSatisfy { $0.vote >= 5 }
        return approved ? "APPROVED" : "REVIEW_REQUIRED"
    }

    var pullRequest: PullRequest {
        let branch = { (ref: String) in ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref }
        return PullRequest(
            number: pullRequestId, title: title,
            state: ["active": "OPEN", "completed": "MERGED"][status] ?? "CLOSED",
            url: "\(repository.webUrl)/pullrequest/\(pullRequestId)", isDraft: isDraft ?? false,
            headRefName: branch(sourceRefName), baseRefName: branch(targetRefName), reviewDecision: reviewDecision)
    }
}

/// One branch-policy evaluation from `az repos pr policy list` — Azure's equivalent of a check.
struct AzurePolicyEvaluation: Decodable {
    /// `approved` / `rejected` / `broken` / `running` / `queued` / `notApplicable`.
    var status: String
    var configuration: Configuration
    struct Configuration: Decodable {
        var type: Named
        var settings: Settings?
        struct Named: Decodable { var displayName: String }
        struct Settings: Decodable { var displayName: String? }
    }

    var check: PullRequest.Check {
        let name = configuration.settings?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.type.displayName
        switch status {
        case "approved": return .init(name: name, status: "COMPLETED", conclusion: "SUCCESS")
        case "rejected", "broken": return .init(name: name, status: "COMPLETED", conclusion: "FAILURE")
        case "notApplicable": return .init(name: name, status: "COMPLETED", conclusion: "NEUTRAL")
        case "running": return .init(name: name, status: "IN_PROGRESS")
        default: return .init(name: name, status: "QUEUED")
        }
    }
}

/// `az repos pr` (azure-devops extension). Organization/project/repo come from `--detect`, i.e.
/// az reads origin itself; auth is `az login` (or `AZURE_DEVOPS_EXT_PAT`), never Gitunia's.
extension RepositoryStore {
    func azurePullRequest(for branch: String) async -> PullRequest? {
        do {
            let out = try await az.run(["repos", "pr", "list", "--source-branch=\(branch)", "--status", "all",
                                        "--top", "1", "--output", "json"], in: url)
            lastGHError = nil
            guard var pr = try JSONDecoder().decode([AzurePullRequest].self, from: Data(out.utf8)).first?.pullRequest else { return nil }
            pr.statusCheckRollup = await azurePolicyChecks(id: pr.number)
            return pr
        } catch {
            lastGHError = (error as? LocalizedError)?.errorDescription ?? "az: \(error)"
            return nil
        }
    }

    /// Policies of a PR as checks; nil (no checks row) when az fails — the PR itself still shows.
    func azurePolicyChecks(id: Int) async -> [PullRequest.Check]? {
        guard let out = try? await az.run(["repos", "pr", "policy", "list", "--id=\(id)", "--output", "json"], in: url),
              let evaluations = try? JSONDecoder().decode([AzurePolicyEvaluation].self, from: Data(out.utf8)) else { return nil }
        return evaluations.map(\.check)
    }

    func createAzurePullRequest(title: String, body: String, draft: Bool, base: String?, branch: String) async -> Result<PullRequest, GHError> {
        // `--flag=value`: az is argparse, which would read a value starting with `-` as a flag.
        var args = ["repos", "pr", "create", "--title=\(title)", "--source-branch=\(branch)", "--output", "json"]
        if !body.isEmpty { args.append("--description=\(body)") }
        if draft { args += ["--draft", "true"] }
        if let base, !base.isEmpty { args.append("--target-branch=\(base)") }
        do {
            let out = try await az.run(args, in: url)
            let pr = try JSONDecoder().decode(AzurePullRequest.self, from: Data(out.utf8)).pullRequest
            pullRequest = pr
            return .success(pr)
        } catch let error as GHError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
