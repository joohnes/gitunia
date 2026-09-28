import SwiftUI
import GituniaCore

/// Checks GitHub Releases for a newer Gitunia build. When it can (setting on, signed build, app in a
/// writable folder) it downloads and verifies it in the background and offers "Restart"; otherwise
/// it toasts "Download" (opens the dmg/release page in the browser). One per app (`GituniaApp`),
/// same lifetime as `RemoteOpsCoordinator`/`EditorOpenCoordinator`.
@MainActor
@Observable
final class UpdateCoordinator {
    private let app: AppConfig
    private let toasts: ToastCenter
    private let checker: UpdateChecker
    private let installer: any UpdateInstalling
    /// Injectable so a test (and `swift run`, which has no bundle) can run without `Bundle.main`.
    private let bundleVersion: String?
    private let hasBundle: Bool
    private let now: @Sendable () -> Date
    @ObservationIgnored private var startedLoop = false

    /// The most recent release `latest()` returned, for Settings to render — regardless of whether
    /// it's newer than this build.
    private(set) var latestKnown: ReleaseInfo?
    /// A downloaded, verified update waiting for a restart (or the next quit).
    private(set) var prepared: PreparedUpdate?
    /// A check is in flight — Settings' spinner.
    private(set) var isChecking = false
    /// The last check couldn't reach GitHub Releases — Settings says so, since toasts only show in
    /// workspace windows, not in the Settings window.
    private(set) var lastCheckFailed = false

    /// This build's version, for Settings ("dev" under `swift run`).
    var currentVersion: String { bundleVersion ?? "dev" }

    init(app: AppConfig, toasts: ToastCenter, checker: UpdateChecker = UpdateChecker(),
         installer: any UpdateInstalling = UpdateInstaller.forRunningApp(),
         bundleVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
         hasBundle: Bool = Bundle.main.bundleIdentifier != nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.app = app
        self.toasts = toasts
        self.checker = checker
        self.installer = installer
        self.bundleVersion = bundleVersion
        self.hasBundle = hasBundle
        self.now = now
    }

    /// A release newer than this build that the user hasn't skipped — what Settings → Updates
    /// shows "Latest: <version>" for.
    var availableUpdate: ReleaseInfo? {
        guard let latestKnown, let bundleVersion,
              UpdateChecker.isNewer(latestKnown.version, than: bundleVersion),
              latestKnown.version != app.config.updateState.skippedVersion else { return nil }
        return latestKnown
    }

    /// Settings → Updates toggle off, `swift run`/tests (no bundle), or fired under 24h ago all
    /// skip silently — `force` (the menu item) overrides every gate but the network call itself.
    /// Returns the check's `Task` (nil when a gate skipped it) so tests can await a deterministic
    /// result instead of polling for a toast.
    @discardableResult
    func checkIfDue(force: Bool = false) -> Task<Void, Never>? {
        guard force || app.settings.checkForUpdates else { return nil }
        guard force || hasBundle else { return nil }
        if !force, let last = app.config.updateState.lastCheck, now().timeIntervalSince(last) < 24 * 60 * 60 { return nil }
        return Task { await performCheck(force: force) }
    }

    /// WorkspaceWindow's launch `.task` calls this once per window; the first call starts the 6h
    /// loop (the 24h gate in `checkIfDue` is what actually throttles), later calls are a no-op past
    /// that first immediate check.
    func startIfNeeded() {
        checkIfDue()
        guard !startedLoop else { return }
        startedLoop = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled, let self else { return }
                self.checkIfDue()
            }
        }
    }

    /// Settings → Updates "Skip this version".
    func skip(_ version: String) {
        app.skipUpdate(version: version)
        if prepared?.version == version { prepared = nil }
    }

    /// Why "Install updates automatically" is unavailable, for Settings' footnote; nil when it isn't.
    var autoInstallBlocker: String? {
        if !installer.hasPublicKey { return "This build can't verify updates" }
        if !installer.canReplaceApp { return "Move Gitunia to /Applications to enable automatic updates" }
        return nil
    }

    /// Toast/Settings "Restart": hand off to the swap script, then quit.
    func restartToUpdate() {
        guard let prepared else { return }
        do {
            try installer.install(prepared, relaunch: true)
            self.prepared = nil   // so the terminate hook doesn't launch a second script
            NSApp.terminate(nil)
        } catch {
            toasts.post(.error("Couldn't install the update", detail: error.localizedDescription))
        }
    }

    /// `AppDelegate.onTerminate`: a prepared update installs on a normal quit too, without relaunch.
    func installOnQuitIfPrepared() {
        guard let prepared, app.settings.autoInstallUpdates else { return }
        self.prepared = nil
        try? installer.install(prepared, relaunch: false)
    }

    private func performCheck(force: Bool) async {
        app.noteUpdateCheck()
        isChecking = true
        let latest = await checker.latest()
        isChecking = false
        lastCheckFailed = latest == nil
        guard let release = latest else {
            if force { toasts.post(Toast(style: .info, title: "Couldn't check for updates")) }
            return
        }
        latestKnown = release
        guard let bundleVersion else { return }
        guard UpdateChecker.isNewer(release.version, than: bundleVersion) else {
            if force { toasts.post(Toast(style: .info, title: "You're up to date (\(bundleVersion))")) }
            return
        }
        guard release.version != app.config.updateState.skippedVersion else { return }
        if app.settings.autoInstallUpdates, autoInstallBlocker == nil {
            if prepared?.version == release.version { return postReady(release.version) }
            do {
                prepared = try await installer.prepare(release)
                return postReady(release.version)
            } catch UpdateInstallError.badSignature {
                toasts.post(.error("The downloaded update failed verification and was discarded"))
            } catch {
                // Network, disk image or bundle problems: say why, then offer the manual download below.
                toasts.post(.error("Couldn't download the update", detail: Self.reason(for: error)))
            }
        }
        let detail = release.notes?.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Download from GitHub"
        let dmgURL = release.dmgURL, htmlURL = release.htmlURL
        toasts.post(Toast(style: .info, title: "Gitunia \(release.version) is available", detail: detail,
                          action: ToastAction(title: "Download") {
            Task { @MainActor in NSWorkspace.shared.open(dmgURL ?? htmlURL) }
        }))
    }

    /// One short, human sentence for a failed `prepare` — the detail line of the error toast.
    static func reason(for error: Error) -> String {
        switch error {
        case UpdateInstallError.noSignature: return "The release has no signature file."
        case UpdateInstallError.noPublicKey: return "This build can't verify updates."
        case UpdateInstallError.wrongBundle: return "The download didn't contain the expected Gitunia version."
        case UpdateInstallError.differentSigner:
            return "The update is signed by a different certificate — installing it would reset Gitunia's folder access. Download it manually if you trust it."
        case UpdateInstallError.failed(let message): return message
        case let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost:
            return "You're offline."
        case let e as URLError where e.code == .timedOut: return "The download timed out."
        default: return error.localizedDescription
        }
    }

    private func postReady(_ version: String) {
        toasts.post(Toast(style: .info, title: "Gitunia \(version) is ready — restart to update",
                          action: ToastAction(title: "Restart") { [weak self] in
            Task { @MainActor in self?.restartToUpdate() }
        }))
    }
}
