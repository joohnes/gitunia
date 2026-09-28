import XCTest
@testable import GituniaCore

final class GitHubURLTests: XCTestCase {
    private let expected = "https://github.com/acme/app/pull/42"

    func testHTTPS() {
        XCTAssertEqual(GitHubURL.pull(remoteURL: "https://github.com/acme/app.git", number: 42)?.absoluteString, expected)
        XCTAssertEqual(GitHubURL.pull(remoteURL: "https://github.com/acme/app", number: 42)?.absoluteString, expected)
        XCTAssertEqual(GitHubURL.pull(remoteURL: "https://jan:tok@github.com/acme/app.git\n", number: 42)?.absoluteString, expected)
    }

    func testSSH() {
        XCTAssertEqual(GitHubURL.pull(remoteURL: "git@github.com:acme/app.git", number: 42)?.absoluteString, expected)
        XCTAssertEqual(GitHubURL.pull(remoteURL: "ssh://git@github.com/acme/app.git", number: 42)?.absoluteString, expected)
    }

    func testNonGitHub() {
        XCTAssertNil(GitHubURL.pull(remoteURL: "https://gitlab.com/acme/app.git", number: 1))
        XCTAssertNil(GitHubURL.pull(remoteURL: "git@example.com:acme/app.git", number: 1))
        XCTAssertNil(GitHubURL.pull(remoteURL: "/tmp/origin.git", number: 1))
        XCTAssertNil(GitHubURL.pull(remoteURL: "https://github.com.evil.io/acme/app", number: 1))
    }
}
