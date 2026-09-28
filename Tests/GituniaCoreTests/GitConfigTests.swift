import XCTest
@testable import GituniaCore

final class GitConfigTests: XCTestCase {
    private let sample = """
    unknown\tfile:/Applications/Xcode.app/Contents/Developer/usr/share/git-core/gitconfig\tinit.defaultbranch=master
    global\tfile:/Users/jan/My Config/.gitconfig\tpush.default=simple
    global\tfile:/Users/jan/My Config/.gitconfig\tuser.name=Jan Kowalski
    global\tfile:/Users/jan/My Config/.gitconfig\talias.lg=log --format=%h %s
    local\tfile:.git/config\tpush.default=current
    local\tfile:.git/config\tcommit.gpgsign
    command\tcommand line:\tcore.quotepath=false
    """

    func testParseConfigList_fieldsSpacesAndEquals() {
        let entries = RepositoryStore.parseConfigList(sample)
        XCTAssertEqual(entries.count, 6, "command-scope (-c hardening) entries are dropped")
        XCTAssertEqual(entries[0].scope, .system)
        XCTAssertEqual(entries[1].origin, "file:/Users/jan/My Config/.gitconfig")
        XCTAssertEqual(entries[2].value, "Jan Kowalski")
        XCTAssertEqual(entries[3].key, "alias.lg")
        XCTAssertEqual(entries[3].value, "log --format=%h %s")
        XCTAssertEqual(entries[5].value, "true", "bare key means true")
    }

    func testResolve_localOverridesGlobal() {
        let values = RepositoryStore.resolve(RepositoryStore.parseConfigList(sample),
                                             keys: ["push.default", "user.name", "init.defaultBranch", "fetch.prune", "commit.gpgsign"])
        XCTAssertEqual(values[0], ConfigValue(key: "push.default", value: "current", scope: .local, inherited: "simple"))
        XCTAssertEqual(values[1], ConfigValue(key: "user.name", value: "Jan Kowalski", scope: .global, inherited: "Jan Kowalski"))
        XCTAssertEqual(values[2].scope, .system, "catalog keys match git's lowercased names")
        XCTAssertEqual(values[3], ConfigValue(key: "fetch.prune", value: nil, scope: .unset))
        XCTAssertEqual(values[4], ConfigValue(key: "commit.gpgsign", value: "true", scope: .local))
    }

    @MainActor
    func testSetAndUnsetLocal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await GitRunner().run(["init", "-q", "-b", "master"], in: url)
        let store = RepositoryStore(url: url)

        let setError = await store.setConfig("push.default", value: "current", scope: .local)
        XCTAssertNil(setError)
        var value = await store.configValues(for: ["push.default"])[0]
        XCTAssertEqual(value.value, "current")
        XCTAssertEqual(value.scope, .local)

        let unsetError = await store.setConfig("push.default", value: nil, scope: .local)
        XCTAssertNil(unsetError)
        value = await store.configValues(for: ["push.default"])[0]
        XCTAssertNotEqual(value.scope, .local)
        let again = await store.setConfig("push.default", value: nil, scope: .local)
        XCTAssertNil(again, "unsetting an unset key is not an error")
    }
}
