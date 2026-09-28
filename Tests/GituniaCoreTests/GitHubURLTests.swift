import XCTest
@testable import GituniaCore

final class GitHubURLTests: XCTestCase {
    func testPullURL() {
        let expected = "https://github.com/acme/app/pull/42"
        let cases: [(remote: String, url: String?)] = [
            ("https://github.com/acme/app.git", expected),
            ("https://github.com/acme/app", expected),
            ("https://jan:tok@github.com/acme/app.git\n", expected),
            ("git@github.com:acme/app.git", expected),
            ("ssh://git@github.com/acme/app.git", expected),
            ("https://gitlab.com/acme/app.git", nil),
            ("git@example.com:acme/app.git", nil),
            ("/tmp/origin.git", nil),
            ("https://github.com.evil.io/acme/app", nil),
        ]
        for c in cases {
            XCTAssertEqual(GitHubURL.pull(remoteURL: c.remote, number: 42)?.absoluteString, c.url, c.remote)
        }
    }
}
