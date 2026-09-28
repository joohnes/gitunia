import XCTest
@testable import GituniaCore

final class UpdateCheckerTests: XCTestCase {
    private static let releaseJSON = """
    {
      "tag_name": "v1.4.0",
      "html_url": "https://github.com/joohnes/gitunia/releases/tag/v1.4.0",
      "body": "Fixes a crash on launch.\\n\\nAlso some polish.",
      "published_at": "2026-01-02T03:04:05Z",
      "draft": false,
      "prerelease": false,
      "assets": [
        {"browser_download_url": "https://github.com/joohnes/gitunia/releases/download/v1.4.0/Gitunia.zip"},
        {"browser_download_url": "https://github.com/joohnes/gitunia/releases/download/v1.4.0/Gitunia.dmg"},
        {"browser_download_url": "https://github.com/joohnes/gitunia/releases/download/v1.4.0/Gitunia.dmg.sig"},
        {"browser_download_url": "https://github.com/joohnes/gitunia/releases/download/v1.4.0/SHA256SUMS.txt"}
      ]
    }
    """

    private static let prereleaseJSON = """
    {"tag_name": "v2.0.0-beta", "html_url": "https://example.com", "draft": false, "prerelease": true, "assets": []}
    """

    func testParseRealisticFixture() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(Data(Self.releaseJSON.utf8)))
        XCTAssertEqual(info.tag, "v1.4.0")
        XCTAssertEqual(info.version, "1.4.0")
        XCTAssertEqual(info.htmlURL.absoluteString, "https://github.com/joohnes/gitunia/releases/tag/v1.4.0")
        XCTAssertEqual(info.dmgURL?.absoluteString, "https://github.com/joohnes/gitunia/releases/download/v1.4.0/Gitunia.dmg")
        XCTAssertEqual(info.signatureURL?.absoluteString, "https://github.com/joohnes/gitunia/releases/download/v1.4.0/Gitunia.dmg.sig")
        XCTAssertEqual(info.notes, "Fixes a crash on launch.\n\nAlso some polish.")
        XCTAssertNotNil(info.publishedAt)
    }

    func testParseWithoutSigHasNilSignatureURL() throws {
        let json = #"{"tag_name": "v1.0", "html_url": "https://example.com", "draft": false, "prerelease": false, "assets": [{"browser_download_url": "https://example.com/Gitunia-1.0.dmg"}]}"#
        let info = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertNotNil(info.dmgURL)
        XCTAssertNil(info.signatureURL)
    }

    func testParsePrereleaseReturnsNil() {
        XCTAssertNil(UpdateChecker.parse(Data(Self.prereleaseJSON.utf8)))
    }

    func testIsNewerTable() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0", than: "0.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0", than: "1.0.0"), "v1.0 == 1.0.0")
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1"), "0.1.0 == 0.1")
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "garbage"), "unparseable components read as 0, so 1.0.0 beats it")
    }
}
