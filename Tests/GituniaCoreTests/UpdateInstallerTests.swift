import CryptoKit
import XCTest
@testable import GituniaCore

final class UpdateInstallerTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()

    /// A real dmg holding a fake `Gitunia.app`, plus its base64 `.sig`, in `dir`. `adHocSign` puts an
    /// executable in the bundle and signs it ad-hoc, so `codesign --verify -R` has something to check.
    private func makeDMG(in dir: URL, version: String = "2.0.0", bundleID: String = "dev.gitunia.app",
                         adHocSign: Bool = false) throws -> (dmg: URL, sig: URL) {
        let src = dir.appendingPathComponent("src"), contents = src.appendingPathComponent("Gitunia.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        if adHocSign { plist["CFBundleExecutable"] = "Gitunia" }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if adHocSign {
            try Self.adHocSignedBundle(at: src.appendingPathComponent("Gitunia.app"))
        }
        let dmg = dir.appendingPathComponent("Gitunia-\(version).dmg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-quiet", "-srcfolder", src.path, "-volname", "Gitunia", "-format", "UDRO", "-ov", dmg.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "hdiutil create")
        let sig = dir.appendingPathComponent(dmg.lastPathComponent + ".sig")
        try (try key.signature(for: Data(contentsOf: dmg)).base64EncodedString() + "\n").write(to: sig, atomically: true, encoding: .utf8)
        return (dmg, sig)
    }

    private func release(_ version: String = "2.0.0") -> ReleaseInfo {
        ReleaseInfo(tag: "v\(version)", version: version, htmlURL: URL(string: "https://example.com")!,
                    dmgURL: URL(string: "https://example.com/Gitunia-\(version).dmg"),
                    signatureURL: URL(string: "https://example.com/Gitunia-\(version).dmg.sig"), notes: nil, publishedAt: nil)
    }

    /// Serves local files by the request's `.sig`-ness, copying so `prepare` can move them.
    /// `pinned` stands in for the running app's designated requirement (nil = nothing pinned).
    private func installer(dir: URL, dmg: URL, sig: URL, publicKey: Data?, pinned: String? = nil) -> UpdateInstaller {
        let staging = dir.appendingPathComponent("downloads")
        return UpdateInstaller(publicKey: publicKey, appURL: dir.appendingPathComponent("Applications/Gitunia.app"),
                               workDir: dir.appendingPathComponent("work"), pinnedRequirement: { _ in pinned }) { url in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let out = staging.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url.pathExtension == "sig" ? sig : dmg, to: out)
            return out
        }
    }

    func testVerify() throws {
        let dir = try TestHelpers.makeTempDir()
        let file = dir.appendingPathComponent("blob")
        try Data("hello".utf8).write(to: file)
        let sig = try key.signature(for: Data("hello".utf8))
        XCTAssertTrue(UpdateInstaller.verify(dmg: file, signature: sig, publicKey: key.publicKey.rawRepresentation))
        XCTAssertFalse(UpdateInstaller.verify(dmg: file, signature: sig, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertFalse(UpdateInstaller.verify(dmg: file, signature: Data(repeating: 0, count: 64), publicKey: key.publicKey.rawRepresentation))
    }

    func testPrepareReturnsVerifiedBundle() async throws {
        let dir = try TestHelpers.makeTempDir()
        let (dmg, sig) = try makeDMG(in: dir)
        let inst = installer(dir: dir, dmg: dmg, sig: sig, publicKey: key.publicKey.rawRepresentation)
        let prepared = try await inst.prepare(release())
        XCTAssertEqual(prepared.version, "2.0.0")
        XCTAssertEqual(prepared.bundleURL.path, dir.appendingPathComponent("work/Gitunia.app").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.bundleURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work/mnt/Gitunia.app").path), "detached")
    }

    func testTamperedDMGIsBadSignature() async throws {
        let dir = try TestHelpers.makeTempDir()
        // Signature is checked before hdiutil ever sees the file, so any bytes will do (no slow dmg build).
        let dmg = dir.appendingPathComponent("Gitunia-2.0.0.dmg"), sig = dir.appendingPathComponent("Gitunia-2.0.0.dmg.sig")
        try Data("original".utf8).write(to: dmg)
        try (try key.signature(for: Data("original".utf8)).base64EncodedString() + "\n").write(to: sig, atomically: true, encoding: .utf8)
        let h = try FileHandle(forWritingTo: dmg); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        let inst = installer(dir: dir, dmg: dmg, sig: sig, publicKey: key.publicKey.rawRepresentation)
        await assertThrows(UpdateInstallError.badSignature) { _ = try await inst.prepare(self.release()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work").path), "discarded")
    }

    func testMissingPublicKey() async throws {
        let dir = try TestHelpers.makeTempDir()
        let inst = installer(dir: dir, dmg: dir, sig: dir, publicKey: nil)
        await assertThrows(UpdateInstallError.noPublicKey) { _ = try await inst.prepare(self.release()) }
    }

    func testWrongVersionInBundle() async throws {
        let dir = try TestHelpers.makeTempDir()
        let (dmg, sig) = try makeDMG(in: dir, version: "1.9.0")
        let inst = installer(dir: dir, dmg: dmg, sig: sig, publicKey: key.publicKey.rawRepresentation)
        await assertThrows(UpdateInstallError.wrongBundle) { _ = try await inst.prepare(self.release("2.0.0")) }
    }

    func testCanReplace() throws {
        XCTAssertFalse(UpdateInstaller.canReplace(appURL: URL(fileURLWithPath: "/Volumes/Gitunia/Gitunia.app")))
        XCTAssertFalse(UpdateInstaller.canReplace(appURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Gitunia.app")))
        let dir = try TestHelpers.makeTempDir()
        XCTAssertTrue(UpdateInstaller.canReplace(appURL: dir.appendingPathComponent("Gitunia.app")))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertFalse(UpdateInstaller.canReplace(appURL: dir.appendingPathComponent("Gitunia.app")))
    }

    func testInstallScriptQuotesPathsAndWaitsOnPID() {
        let script = UpdateInstaller.installScript(pid: 4242, appURL: URL(fileURLWithPath: "/Apps/It's Gitunia.app"),
                                                   newApp: URL(fileURLWithPath: "/tmp/w k/Gitunia.app"),
                                                   workDir: URL(fileURLWithPath: "/tmp/w k"), relaunch: true)
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains(#"mv '/Apps/It'\''s Gitunia.app' '/tmp/w k/old.app'"#))
        XCTAssertTrue(script.contains(#"mv '/tmp/w k/Gitunia.app' '/Apps/It'\''s Gitunia.app'"#))
        XCTAssertTrue(script.contains(#"open '/Apps/It'\''s Gitunia.app'"#))
        XCTAssertLessThanOrEqual(script.split(separator: "\n").count, 25)
        let noRelaunch = UpdateInstaller.installScript(pid: 1, appURL: URL(fileURLWithPath: "/A.app"), newApp: URL(fileURLWithPath: "/w/B.app"),
                                                       workDir: URL(fileURLWithPath: "/w"), relaunch: false)
        XCTAssertFalse(noRelaunch.contains("open "))
    }

    func testBundledPublicKey() {
        XCTAssertNil(UpdateInstaller.bundledPublicKey(nil))
        XCTAssertNil(UpdateInstaller.bundledPublicKey(["GituniaUpdatePublicKey": ""]))
        XCTAssertEqual(UpdateInstaller.bundledPublicKey(["GituniaUpdatePublicKey": "AAEC"]), Data([0, 1, 2]))
    }

    /// Copies `/usr/bin/true` in as the executable and re-signs the bundle ad-hoc.
    static func adHocSignedBundle(at app: URL) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Gitunia").path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", app.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "codesign ad-hoc")
    }

    private let certRequirement = #"identifier "dev.gitunia.app" and certificate leaf = H"bdd972e5194cb10a9b6851d0619b9c04c1635ab0""#

    func testPinnedRequirementFromCertificateSignedApp() {
        let out = "Executable=/Applications/Gitunia.app/Contents/MacOS/Gitunia\ndesignated => \(certRequirement)\n"
        XCTAssertEqual(UpdateInstaller.pinnedRequirement(codesignDisplay: out), certRequirement)
    }

    /// Review focus 1: today's ad-hoc builds must accept the first certificate-signed update.
    func testAdHocRunningAppPinsNothing() {
        XCTAssertNil(UpdateInstaller.pinnedRequirement(codesignDisplay: "# designated => cdhash H\"328a39f4c3dd3636ed90a17931c69166ccb7cdf6\"\n"))
        XCTAssertNil(UpdateInstaller.pinnedRequirement(codesignDisplay: "designated => cdhash H\"328a39f4c3dd3636ed90a17931c69166ccb7cdf6\"\n"))
    }

    /// Review focus 2: an unreadable or unsigned running app must not block updates.
    func testUnsignedOrUnreadablePinsNothing() async throws {
        XCTAssertNil(UpdateInstaller.pinnedRequirement(codesignDisplay: ""))
        XCTAssertNil(UpdateInstaller.pinnedRequirement(codesignDisplay: "Gitunia.app: code object is not signed at all\n"))
        let missing = try TestHelpers.makeTempDir().appendingPathComponent("Nope.app")
        let pinned = await UpdateInstaller.runningAppRequirement(missing)
        XCTAssertNil(pinned)
    }

    func testSatisfiesChecksTheRealSignature() async throws {
        let app = try TestHelpers.makeTempDir().appendingPathComponent("Gitunia.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.gitunia.app", "CFBundleExecutable": "Gitunia"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Self.adHocSignedBundle(at: app)
        let sameIdentifier = await UpdateInstaller.satisfies(app, requirement: #"identifier "dev.gitunia.app""#)
        let otherCertificate = await UpdateInstaller.satisfies(app, requirement: certRequirement)
        XCTAssertTrue(sameIdentifier)
        XCTAssertFalse(otherCertificate)
    }

    /// Review focus 5: the way through to a paid Developer ID certificate later. Positive case on an
    /// installed Developer ID app when the machine has one; an ad-hoc bundle must never pass.
    /// The Developer ID fallback must not let an ad-hoc (anyone-can-make) signature through.
    func testDeveloperIDRequirementRejectsAdHoc() async throws {
        let app = try TestHelpers.makeTempDir().appendingPathComponent("Gitunia.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.gitunia.app", "CFBundleExecutable": "Gitunia"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Self.adHocSignedBundle(at: app)
        let adHocPasses = await UpdateInstaller.satisfies(app, requirement: UpdateInstaller.developerIDRequirement(identifier: "dev.gitunia.app"))
        XCTAssertFalse(adHocPasses)
    }

    func testPrepareRefusesUpdateFromDifferentSigner() async throws {
        let dir = try TestHelpers.makeTempDir()
        let (dmg, sig) = try makeDMG(in: dir, adHocSign: true)
        let inst = installer(dir: dir, dmg: dmg, sig: sig, publicKey: key.publicKey.rawRepresentation,
                             pinned: certRequirement)
        await assertThrows(UpdateInstallError.differentSigner) { _ = try await inst.prepare(self.release()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work").path), "discarded")
    }

    func testPrepareAcceptsUpdateMeetingThePin() async throws {
        let dir = try TestHelpers.makeTempDir()
        let (dmg, sig) = try makeDMG(in: dir, adHocSign: true)
        let inst = installer(dir: dir, dmg: dmg, sig: sig, publicKey: key.publicKey.rawRepresentation,
                             pinned: #"identifier "dev.gitunia.app""#)
        let prepared = try await inst.prepare(release())
        XCTAssertEqual(prepared.version, "2.0.0")
    }

    private func assertThrows(_ expected: UpdateInstallError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? UpdateInstallError, expected, file: file, line: line) }
    }
}
