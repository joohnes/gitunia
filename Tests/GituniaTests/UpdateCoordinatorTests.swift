import XCTest
@testable import Gitunia
import GituniaCore

/// Counts fetches without needing a running network stack — `UpdateChecker`'s `fetch` closure is
/// `@Sendable`, so this needs to be safe to call from wherever `Task { }` happens to run it.
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func hit() -> Int { lock.withLock { _count += 1; return _count } }
}

/// `UpdateInstalling` stand-in: records `prepare` calls and returns/throws a canned result.
private final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepareCalls = 0
    var prepareCalls: Int { lock.withLock { _prepareCalls } }
    let hasPublicKey: Bool
    let canReplaceApp: Bool
    let error: UpdateInstallError?
    init(hasPublicKey: Bool = true, canReplaceApp: Bool = true, error: UpdateInstallError? = nil) {
        self.hasPublicKey = hasPublicKey; self.canReplaceApp = canReplaceApp; self.error = error
    }
    func prepare(_ release: ReleaseInfo) async throws -> PreparedUpdate {
        lock.withLock { _prepareCalls += 1 }
        if let error { throw error }
        return PreparedUpdate(version: release.version, bundleURL: URL(fileURLWithPath: "/nonexistent/Gitunia.app"))
    }
    func install(_ prepared: PreparedUpdate, relaunch: Bool) throws {}
}

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    private static let releaseJSON = """
    {"tag_name": "v9.9.9", "html_url": "https://example.com/releases/tag/v9.9.9",
     "body": "Line one.\\nLine two.", "draft": false, "prerelease": false,
     "assets": [{"browser_download_url": "https://example.com/Gitunia.dmg"}]}
    """

    private func makeApp() throws -> AppConfig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppConfig(configStore: ConfigStore(fileURL: dir.appendingPathComponent("workspace.json")))
    }

    private func makeCoordinator(app: AppConfig, toasts: ToastCenter, json: String,
                                  installer: any UpdateInstalling = FakeInstaller(hasPublicKey: false),
                                  bundleVersion: String? = "1.0.0", hasBundle: Bool = true,
                                  now: @escaping @Sendable () -> Date = { Date() }) -> (UpdateCoordinator, FetchCounter) {
        let counter = FetchCounter()
        let checker = UpdateChecker(fetch: { _ in
            _ = counter.hit()
            return Data(json.utf8)
        })
        let coordinator = UpdateCoordinator(app: app, toasts: toasts, checker: checker, installer: installer,
                                            bundleVersion: bundleVersion, hasBundle: hasBundle, now: now)
        return (coordinator, counter)
    }

    func testNewerVersionPostsOneToastWithTheRightTitle() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let (coordinator, counter) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(toasts.toasts.count, 1)
        XCTAssertEqual(toasts.toasts.first?.title, "Gitunia 9.9.9 is available")
        XCTAssertEqual(toasts.toasts.first?.detail, "Line one.")
        XCTAssertNotNil(toasts.toasts.first?.action)
        XCTAssertEqual(coordinator.availableUpdate?.version, "9.9.9")
    }

    func testNewerWithKeyAndReplaceablePreparesAndToastsReady() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let fake = FakeInstaller()
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, installer: fake)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(fake.prepareCalls, 1)
        XCTAssertEqual(coordinator.prepared?.version, "9.9.9")
        XCTAssertEqual(toasts.toasts.map(\.title), ["Gitunia 9.9.9 is ready — restart to update"])
        XCTAssertEqual(toasts.toasts.first?.action?.title, "Restart")

        await coordinator.checkIfDue(force: true)?.value
        XCTAssertEqual(fake.prepareCalls, 1, "already prepared: no second download")
    }

    func testNoPublicKeyFallsBackToDownloadToast() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let fake = FakeInstaller(hasPublicKey: false)
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, installer: fake)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(fake.prepareCalls, 0)
        XCTAssertEqual(toasts.toasts.map(\.title), ["Gitunia 9.9.9 is available"])
        XCTAssertEqual(toasts.toasts.first?.action?.title, "Download")
        XCTAssertEqual(coordinator.autoInstallBlocker, "This build can't verify updates")
    }

    func testNotReplaceableFallsBackToDownloadToast() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let fake = FakeInstaller(canReplaceApp: false)
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, installer: fake)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(fake.prepareCalls, 0)
        XCTAssertEqual(toasts.toasts.map(\.title), ["Gitunia 9.9.9 is available"])
        XCTAssertEqual(coordinator.autoInstallBlocker, "Move Gitunia to /Applications to enable automatic updates")
    }

    func testBadSignatureToastsErrorAndNotReady() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let fake = FakeInstaller(error: .badSignature)
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, installer: fake)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(fake.prepareCalls, 1)
        XCTAssertNil(coordinator.prepared)
        XCTAssertEqual(toasts.toasts.map(\.title), ["The downloaded update failed verification and was discarded", "Gitunia 9.9.9 is available"])
        XCTAssertEqual(toasts.toasts.first?.style, .error)
    }

    func testDownloadFailureToastsReasonThenOffersManualDownload() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let fake = FakeInstaller(error: .failed("hdiutil failed: image not recognized"))
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, installer: fake)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertNil(coordinator.prepared)
        XCTAssertEqual(toasts.toasts.map(\.title), ["Couldn't download the update", "Gitunia 9.9.9 is available"])
        XCTAssertEqual(toasts.toasts.first?.detail, "hdiutil failed: image not recognized")
        XCTAssertEqual(UpdateCoordinator.reason(for: URLError(.notConnectedToInternet)), "You're offline.")
    }

    func testAutoInstallSettingOffSkipsPrepare() async throws {
        let app = try makeApp()
        var settings = app.settings
        settings.autoInstallUpdates = false
        app.updateSettings(settings)
        let toasts = ToastCenter()
        let fake = FakeInstaller()
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, installer: fake)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(fake.prepareCalls, 0)
        XCTAssertEqual(toasts.toasts.map(\.title), ["Gitunia 9.9.9 is available"])
    }

    func testSkippedVersionPostsNoToast() async throws {
        let app = try makeApp()
        app.skipUpdate(version: "9.9.9")
        let toasts = ToastCenter()
        let (coordinator, counter) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(counter.count, 1, "still checks — only the toast is suppressed")
        XCTAssertTrue(toasts.toasts.isEmpty)
        XCTAssertNil(coordinator.availableUpdate)
    }

    func testNotDueSkipsTheFetchEntirely() throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let fixedNow = Date()
        let (coordinator, counter) = makeCoordinator(app: app, toasts: toasts, json: Self.releaseJSON, now: { fixedNow })
        app.noteUpdateCheck()   // lastCheck = "now" (the real Date(), a moment before fixedNow — still < 24h)

        let task = coordinator.checkIfDue()
        XCTAssertNil(task)
        XCTAssertEqual(counter.count, 0)
    }

    func testForcedCheckWithNoUpdateToastsUpToDate() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let currentJSON = """
        {"tag_name": "v1.0.0", "html_url": "https://example.com", "draft": false, "prerelease": false, "assets": []}
        """
        let (coordinator, _) = makeCoordinator(app: app, toasts: toasts, json: currentJSON, bundleVersion: "1.0.0")

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(toasts.toasts.first?.title, "You're up to date (1.0.0)")
    }

    func testForcedCheckFetchFailureToastsCouldntCheck() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let checker = UpdateChecker(fetch: { _ in throw URLError(.notConnectedToInternet) })
        let coordinator = UpdateCoordinator(app: app, toasts: toasts, checker: checker, installer: FakeInstaller(), bundleVersion: "1.0.0", hasBundle: true)

        await coordinator.checkIfDue(force: true)?.value

        XCTAssertEqual(toasts.toasts.first?.title, "Couldn't check for updates")
        XCTAssertTrue(coordinator.lastCheckFailed, "Settings shows the failure inline")
        XCTAssertFalse(coordinator.isChecking)
    }

    func testUnforcedFetchFailureStaysSilent() async throws {
        let app = try makeApp()
        let toasts = ToastCenter()
        let checker = UpdateChecker(fetch: { _ in throw URLError(.notConnectedToInternet) })
        let coordinator = UpdateCoordinator(app: app, toasts: toasts, checker: checker, installer: FakeInstaller(), bundleVersion: "1.0.0", hasBundle: true)

        await coordinator.checkIfDue()?.value

        XCTAssertTrue(toasts.toasts.isEmpty)
    }
}
