import XCTest
@testable import Gitunia

/// `EditorLauncher.needsPrompt` is the pure decision behind item 4's "ask which editor to use,
/// remember it, use it from then on": no silent fallback to the system default, whether nothing
/// is configured yet or the configured app was since uninstalled.
final class EditorLauncherTests: XCTestCase {
    func testNoConfiguredEditorNeedsPrompt() {
        XCTAssertTrue(EditorLauncher.needsPrompt(configuredBundleID: nil, isInstalled: { _ in true }))
    }

    func testConfiguredAndInstalledDoesNotNeedPrompt() {
        XCTAssertFalse(EditorLauncher.needsPrompt(configuredBundleID: "com.microsoft.VSCode", isInstalled: { _ in true }))
    }

    func testConfiguredButUninstalledNeedsPromptAgain() {
        XCTAssertTrue(EditorLauncher.needsPrompt(configuredBundleID: "com.microsoft.VSCode", isInstalled: { _ in false }))
    }
}
