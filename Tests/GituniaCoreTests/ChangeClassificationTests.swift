import XCTest
@testable import GituniaCore

final class ChangeClassificationTests: XCTestCase {
    func testLockfiles() {
        for path in ["package-lock.json", "web/yarn.lock", "a/b/pnpm-lock.yaml", "Cargo.lock",
                     "Package.resolved", "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                     "Gemfile.lock", "poetry.lock", "uv.lock", "composer.lock", "svc/go.sum", "ios/Podfile.lock",
                     "flake.lock", "bun.lockb", "deps/custom.lock"] {
            XCTAssertTrue(ChangeClassification.isLockfile(path), path)
        }
    }

    func testNonLockfiles() {
        for path in ["lockfile.swift", "Sources/LockManager.swift", "package.json", "go.mod",
                     "yarn.lock.bak", "docs/lock.md", "Cargo.toml"] {
            XCTAssertFalse(ChangeClassification.isLockfile(path), path)
        }
    }
}
