import XCTest
@testable import GituniaCore

final class SecretScannerTests: XCTestCase {
    func testCleanDiffHasNoMatches() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        +func greet() { print("hello") }
        """
        XCTAssertTrue(SecretScanner.scan(diff).isEmpty)
    }

    func testDetectsPrivateKeyHeader() {
        let diff = "+-----BEGIN RSA PRIVATE KEY-----\n+MIIEpAIBAAKCAQEA...\n"
        XCTAssertEqual(SecretScanner.scan(diff), ["a private key"])
    }

    func testDetectsAWSAccessKeyID() {
        let diff = "+aws_access_key_id = AKIAABCDEFGHIJKLMNOP"
        XCTAssertEqual(SecretScanner.scan(diff), ["an AWS access key ID"])
    }

    func testDetectsGitHubToken() {
        let diff = "+GITHUB_TOKEN=ghp_1234567890abcdefghijklmnopqrstuvwxyz"
        XCTAssertEqual(SecretScanner.scan(diff), ["a GitHub token"])
    }

    func testDetectsSlackToken() {
        // Split so the literal never looks like a real token to GitHub push protection.
        let diff = "+SLACK_BOT_TOKEN=" + "xox" + "b-1234567890-abcdefghijklmno"
        XCTAssertEqual(SecretScanner.scan(diff), ["a Slack token"])
    }

    func testDetectsAPIKey() {
        let diff = "+OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"
        XCTAssertEqual(SecretScanner.scan(diff), ["an API key"])
    }

    func testDetectsGenericSecretAssignment() {
        let diff = "+password: 'sup3rSecretValue123456'"
        XCTAssertEqual(SecretScanner.scan(diff), ["a hardcoded password/secret/token"])
    }

    func testDoesNotFlagShortValues() {
        // Short/placeholder-looking assignments shouldn't trip the generic heuristic.
        let diff = "+token: ''\n+password = \"x\"\n"
        XCTAssertTrue(SecretScanner.scan(diff).isEmpty)
    }

    func testCanReturnMultipleLabelsForMultipleSecrets() {
        let diff = """
        +AKIAABCDEFGHIJKLMNOP
        +ghp_1234567890abcdefghijklmnopqrstuvwxyz
        """
        XCTAssertEqual(Set(SecretScanner.scan(diff)), ["an AWS access key ID", "a GitHub token"])
    }

    func testFindingsMapAddedLinesToFilePathsAndIgnoreRemovedLines() {
        let diff = """
        diff --git a/config/aws.env b/config/aws.env
        index 1111111..2222222 100644
        --- a/config/aws.env
        +++ b/config/aws.env
        @@ -1,2 +1,2 @@
        -OLD_KEY=AKIAZZZZZZZZZZZZZZZZ
        +AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP
        diff --git a/old.env b/old.env
        --- a/old.env
        +++ b/old.env
        @@ -1 +0,0 @@
        -AKIAQQQQQQQQQQQQQQQQ
        """
        XCTAssertEqual(
            SecretScanner.findings(inDiff: diff),
            [SecretScanner.Finding(path: "config/aws.env", label: "an AWS access key ID")]
        )
    }

    func testFindingsInLogAttributeCommitAndPath() {
        let dirty = String(repeating: "a", count: 40), clean = String(repeating: "b", count: 40)
        let log = """
        \(dirty)\u{1f}feat: add keys

        diff --git a/keys.env b/keys.env
        --- a/keys.env
        +++ b/keys.env
        @@ -1 +1,2 @@
        -OLD=AKIAZZZZZZZZZZZZZZZZ
        +AWS=AKIAABCDEFGHIJKLMNOP
        +AGAIN=AKIAABCDEFGHIJKLMNOQ
        \(clean)\u{1f}chore: remove key

        diff --git a/old.env b/old.env
        --- a/old.env
        +++ b/old.env
        @@ -1 +1 @@
        -AKIAQQQQQQQQQQQQQQQQ
        +nothing here
        """
        XCTAssertEqual(SecretScanner.findings(inLog: log), [
            SecretScanner.Finding(path: "keys.env", label: "an AWS access key ID", commitHash: dirty, commitSubject: "feat: add keys")
        ])
    }
}
