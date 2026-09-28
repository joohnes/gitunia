import XCTest
@testable import GituniaCore

final class IdentityTests: XCTestCase {
    func testParseNameAndEmailOnly() {
        let id = RepositoryStore.parseIdentity("user.name Jane Doe\nuser.email jane@example.com\n")
        XCTAssertEqual(id, CommitIdentity(name: "Jane Doe", email: "jane@example.com"))
    }

    func testParseSigningSSHAndLaterScopeWins() {
        let id = RepositoryStore.parseIdentity("""
            user.name Global
            commit.gpgsign false
            user.name Local
            user.email l@example.com
            commit.gpgsign true
            gpg.format ssh
            user.signingkey ~/.ssh/id_ed25519.pub
            """)
        XCTAssertEqual(id, CommitIdentity(name: "Local", email: "l@example.com", signingEnabled: true,
                                          signingFormat: "ssh", signingKey: "~/.ssh/id_ed25519.pub"))
        XCTAssertTrue(RepositoryStore.parseIdentity("commit.gpgsign").signingEnabled) // bare key = true
    }

    func testMissingIdentityBlocks() {
        XCTAssertEqual(Preflight.identityWarnings(nil), [])
        let issues = Preflight.identityWarnings(CommitIdentity(name: "Jane"))
        XCTAssertEqual(issues.map(\.severity), [.blocker])
    }

    func testBotEmailWarns() {
        XCTAssertEqual(Preflight.identityWarnings(CommitIdentity(name: "Claude", email: "noreply@anthropic.com")).map(\.id), ["bot-identity"])
        XCTAssertEqual(Preflight.identityWarnings(CommitIdentity(name: "my-bot", email: "1+x@users.noreply.github.com")).map(\.id), ["bot-identity"])
        XCTAssertEqual(Preflight.identityWarnings(CommitIdentity(name: "Jane", email: "1+jane@users.noreply.github.com")), [])
        XCTAssertEqual(Preflight.identityWarnings(CommitIdentity(name: "Jane", email: "jane@example.com")), [])
    }

    @MainActor
    func testCommitIdentityReadsRepoConfig() async throws {
        let url = try await TestHelpers.makeTempRepo()
        _ = try await GitRunner().run(["config", "user.email", "agent@example.com"], in: url)
        let store = RepositoryStore(url: url)
        let id = await store.commitIdentity()
        XCTAssertEqual(id.email, "agent@example.com")
        XCTAssertEqual(id.name, "Test")
        XCTAssertFalse(id.signingEnabled)
        await store.refreshIdentity()
        XCTAssertEqual(store.identity, id)
    }
}
