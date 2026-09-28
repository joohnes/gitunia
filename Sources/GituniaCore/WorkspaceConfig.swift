import Foundation

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case claudeCLI, ollama
    public var displayName: String {
        switch self {
        case .claudeCLI: return "Claude CLI"
        case .ollama: return "Ollama (local)"
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Accent color. Stored as a plain string ("brand"/"system") or `{red, green, blue}` (sRGB, 0…1).
public enum AccentChoice: Codable, Equatable, Hashable, Sendable {
    case brand, system
    case custom(red: Double, green: Double, blue: Double)

    private enum Keys: String, CodingKey { case red, green, blue }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = name == "system" ? .system : .brand
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        self = .custom(red: try c.decode(Double.self, forKey: .red),
                       green: try c.decode(Double.self, forKey: .green),
                       blue: try c.decode(Double.self, forKey: .blue))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .brand, .system:
            var c = encoder.singleValueContainer()
            try c.encode(self == .brand ? "brand" : "system")
        case let .custom(red, green, blue):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(red, forKey: .red)
            try c.encode(green, forKey: .green)
            try c.encode(blue, forKey: .blue)
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var editorBundleID: String?
    public var aiProvider: AIProviderKind = .claudeCLI
    public var ollamaModel: String = "llama3.1"
    public var diffCharLimit: Int = 8000
    public var appearance: AppearanceMode = .system
    public var accent: AccentChoice = .brand
    public var autoFetchMinutes: Int = 15
    public var notificationsEnabled: Bool = false
    public var stripAgentTrailers: Bool = true
    /// Diff remote branches around each fetch into `AppConfig.activity`.
    public var trackRemoteActivity: Bool = true
    public var activityRetentionDays: Int = 14
    /// Checkout with uncommitted changes stashes them (labelled, see `RepositoryStore.stashLabel`)
    /// and switches, instead of asking first.
    public var autoStashOnSwitch: Bool = false
    /// Who counts as an agent; `RepoPrefs.agentPatterns` overrides it per repo.
    public var agentProfile = AgentProfile()
    /// Settings → Updates "Check for updates daily". `WorkspaceConfig.updateState` (not here) holds
    /// when that last happened and any version the user chose to skip.
    public var checkForUpdates: Bool = true
    /// Settings → Updates "Install updates automatically" (`UpdateInstaller`).
    public var autoInstallUpdates: Bool = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case editorBundleID, aiProvider, ollamaModel, diffCharLimit, appearance, accent, autoFetchMinutes, notificationsEnabled, stripAgentTrailers
        case trackRemoteActivity, activityRetentionDays, autoStashOnSwitch, agentProfile, checkForUpdates, autoInstallUpdates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editorBundleID = try c.decodeIfPresent(String.self, forKey: .editorBundleID)
        aiProvider = try c.value(.aiProvider, default: .claudeCLI)
        ollamaModel = try c.value(.ollamaModel, default: "llama3.1")
        diffCharLimit = try c.value(.diffCharLimit, default: 8000)
        appearance = try c.value(.appearance, default: .system)
        accent = try c.value(.accent, default: .brand)
        autoFetchMinutes = try c.value(.autoFetchMinutes, default: 15)
        notificationsEnabled = try c.value(.notificationsEnabled, default: false)
        stripAgentTrailers = try c.value(.stripAgentTrailers, default: true)
        trackRemoteActivity = try c.value(.trackRemoteActivity, default: true)
        activityRetentionDays = try c.value(.activityRetentionDays, default: 14)
        autoStashOnSwitch = try c.value(.autoStashOnSwitch, default: false)
        agentProfile = try c.value(.agentProfile, default: AgentProfile())
        checkForUpdates = try c.value(.checkForUpdates, default: true)
        autoInstallUpdates = try c.value(.autoInstallUpdates, default: true)
    }
}

public struct RepoPrefs: Codable, Equatable, Sendable {
    public var tags: [String] = []
    public var localAIOnly: Bool = false
    public var selectedPath: String?
    public var commitDraft: CommitMessage?
    /// The user's chosen Compare base branch for this repository (T4) — `nil` means "use the
    /// resolved default" (`RepositoryStore.defaultBaseBranch()`), not "no base".
    public var compareBase: String?
    /// Remote for fetch-without-upstream and first push when a repo has several; nil = old behaviour.
    public var defaultRemote: String?
    /// `Repository.fingerprint` when the user last had this repo selected — the unseen dot's baseline.
    public var lastViewedFingerprint: String?
    /// When the fingerprint last changed while Gitunia was watching — the "Recent activity" sort key.
    public var lastActivity: Date?
    /// HEAD when the user last pressed "Mark Reviewed" — History's "Unreviewed" filter is `<this>..HEAD`.
    public var reviewedHead: String?
    /// Per-repo `AgentProfile.patterns`; nil = use `AppSettings.agentProfile`.
    public var agentPatterns: [String]?
    /// How often auto-fetch visits this repo (see `WorkspaceStore.isFetchDue`).
    public var fetchCadence: FetchCadence = .normal
    /// Repo-relative files the user told Gitunia to stop secret-scanning (test fixtures and the like).
    public var secretScanIgnoredPaths: [String] = []
    public init(tags: [String] = [], localAIOnly: Bool = false, selectedPath: String? = nil, commitDraft: CommitMessage? = nil, compareBase: String? = nil) {
        self.tags = tags; self.localAIOnly = localAIOnly
        self.selectedPath = selectedPath; self.commitDraft = commitDraft
        self.compareBase = compareBase
    }

    private enum CodingKeys: String, CodingKey {
        case tags, localAIOnly, selectedPath, commitDraft, compareBase
        case defaultRemote, lastViewedFingerprint, lastActivity, reviewedHead, agentPatterns, fetchCadence
        case secretScanIgnoredPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = try c.value(.tags, default: [])
        localAIOnly = try c.value(.localAIOnly, default: false)
        selectedPath = try c.decodeIfPresent(String.self, forKey: .selectedPath)
        commitDraft = try c.decodeIfPresent(CommitMessage.self, forKey: .commitDraft)
        compareBase = try c.decodeIfPresent(String.self, forKey: .compareBase)
        defaultRemote = try c.decodeIfPresent(String.self, forKey: .defaultRemote)
        lastViewedFingerprint = try c.decodeIfPresent(String.self, forKey: .lastViewedFingerprint)
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        reviewedHead = try c.decodeIfPresent(String.self, forKey: .reviewedHead)
        // `agentPatterns` is itself optional (nil = "use the global profile"): `decodeIfPresent`
        // already gives that for a missing/null key while still throwing on a malformed value, so
        // no `try?`/default needed here.
        agentPatterns = try c.decodeIfPresent([String].self, forKey: .agentPatterns)
        fetchCadence = try c.value(.fetchCadence, default: .normal)
        secretScanIgnoredPaths = try c.value(.secretScanIgnoredPaths, default: [])
    }
}

/// Per-repo auto-fetch frequency: `intensive` every internal tick (5× the Settings interval),
/// `normal` at the Settings interval, `paused` never.
public enum FetchCadence: String, Codable, CaseIterable, Sendable {
    case paused, normal, intensive
}

/// One open window: which workspace file it shows and which repo was selected, so a restart
/// brings every window back as it was.
public struct WindowState: Codable, Equatable, Sendable {
    public var id: UUID
    public var workspace: String
    public var selectedRepo: String?
    public init(id: UUID = UUID(), workspace: String, selectedRepo: String? = nil) {
        self.id = id; self.workspace = workspace; self.selectedRepo = selectedRepo
    }
}

/// `UpdateCoordinator`'s persisted state — when it last checked GitHub Releases, and any version
/// the user dismissed with "Skip this version" in Settings.
public struct UpdateState: Codable, Equatable, Sendable {
    public var lastCheck: Date?
    public var skippedVersion: String?
    public init(lastCheck: Date? = nil, skippedVersion: String? = nil) {
        self.lastCheck = lastCheck
        self.skippedVersion = skippedVersion
    }
}

public struct WorkspaceConfig: Codable, Equatable, Sendable {
    /// Pre-workspace-file versions only: the single scanned folder. Read by `WorkspaceMigration`,
    /// then cleared.
    public var workspacePath: String?
    public var repos: [String: RepoPrefs] = [:]
    public var settings = AppSettings()
    public var windows: [WindowState] = []
    public var recentWorkspaces: [String] = []
    /// Where Clone / New Repository last put a repo — their destination panels start there.
    public var lastRepoParent: String?
    public var updateState = UpdateState()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case workspacePath, repos, settings, windows, recentWorkspaces, lastRepoParent, updateState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        repos = try c.value(.repos, default: [:])
        settings = try c.value(.settings, default: AppSettings())
        windows = try c.value(.windows, default: [])
        recentWorkspaces = try c.value(.recentWorkspaces, default: [])
        lastRepoParent = try c.decodeIfPresent(String.self, forKey: .lastRepoParent)
        updateState = try c.value(.updateState, default: UpdateState())
    }
}

public struct ConfigStore: Sendable {
    public let fileURL: URL

    public static var defaultFileURL: URL {
        AppDataLocation.writableDirectory().appendingPathComponent("workspace.json")
    }

    public init(fileURL: URL = ConfigStore.defaultFileURL) { self.fileURL = fileURL }

    /// When an existing `workspace.json` fails to read or decode (L8), a copy
    /// is preserved next to it (`workspace.json.corrupt-<timestamp>`) before falling back to
    /// defaults, and a human-readable warning describing what happened is returned alongside — the
    /// caller (`WorkspaceStore`) surfaces it so the user knows *why* their prefs, including
    /// `Local AI only`, just reset instead of the reset happening silently.
    public func loadWithWarning() -> (WorkspaceConfig, String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (WorkspaceConfig(), nil) }
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(WorkspaceConfig.self, from: data)
        else {
            let backupURL = FileBackup.preserveCorrupt(at: fileURL)
            let warning = "Your preferences file (\(fileURL.lastPathComponent)) could not be read and has been reset to " +
                "defaults — this includes \"Local AI only\" per repository. A copy of the unreadable file was saved as " +
                "\(backupURL.lastPathComponent)."
            return (WorkspaceConfig(), warning)
        }
        return (cfg, nil)
    }

    public func save(_ config: WorkspaceConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: fileURL, options: .atomic)
    }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent ?? default`: a missing (or null) key falls back, a malformed value still throws.
    func value<T: Decodable>(_ key: Key, default: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? `default`
    }
}
