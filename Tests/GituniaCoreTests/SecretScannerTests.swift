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

    func testDetectsEachKind() {
        let cases: [(diff: String, label: String)] = [
            ("+-----BEGIN RSA PRIVATE KEY-----\n+MIIEpAIBAAKCAQEA...\n", "a private key"),
            ("+aws_access_key_id = AKIAABCDEFGHIJKLMNOP", "an AWS access key ID"),
            ("+GITHUB_TOKEN=ghp_1234567890abcdefghijklmnopqrstuvwxyz", "a GitHub token"),
            // Split so the literal never looks like a real token to GitHub push protection.
            ("+SLACK_BOT_TOKEN=" + "xox" + "b-1234567890-abcdefghijklmno", "a Slack token"),
            ("+OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456", "an API key"),
            ("+password: 'sup3rSecretValue123456'", "a hardcoded password/secret/token"),
        ]
        for c in cases {
            XCTAssertEqual(SecretScanner.scan(c.diff), [c.label], c.label)
        }
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
