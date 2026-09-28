import CryptoKit
import Foundation

/// A verified, unpacked update sitting in `UpdateInstaller.workDir`, ready for `install`.
public struct PreparedUpdate: Equatable, Sendable {
    public let version: String
    /// The new `Gitunia.app`, copied out of the dmg.
    public let bundleURL: URL
    public init(version: String, bundleURL: URL) { self.version = version; self.bundleURL = bundleURL }
}

public enum UpdateInstallError: Error, Equatable {
    case noPublicKey, noSignature, badSignature, wrongBundle
    /// The new app doesn't meet the running app's designated requirement (another certificate).
    case differentSigner
    case failed(String)
}

/// What `UpdateCoordinator` needs from the installer, so its tests can swap in a fake.
public protocol UpdateInstalling: Sendable {
    var hasPublicKey: Bool { get }
    var canReplaceApp: Bool { get }
    func prepare(_ release: ReleaseInfo) async throws -> PreparedUpdate
    func install(_ prepared: PreparedUpdate, relaunch: Bool) throws
}

/// Downloads a release dmg, checks its Curve25519 signature against the key baked into Info.plist
/// (`GituniaUpdatePublicKey`), copies the app out, and swaps it in after the running app quits.
public final class UpdateInstaller: UpdateInstalling {
    public static let bundleIdentifier = "dev.gitunia.app"

    public let publicKey: Data?
    /// The bundle being replaced.
    public let appURL: URL
    public let workDir: URL
    private let download: @Sendable (URL) async throws -> URL
    private let pinnedRequirement: @Sendable (URL) async -> String?

    public init(publicKey: Data?, appURL: URL, workDir: URL,
                pinnedRequirement: @escaping @Sendable (URL) async -> String? = UpdateInstaller.runningAppRequirement,
                download: @escaping @Sendable (URL) async throws -> URL = UpdateInstaller.defaultDownload) {
        self.publicKey = publicKey
        self.appURL = appURL
        self.workDir = workDir
        self.pinnedRequirement = pinnedRequirement
        self.download = download
    }

    /// The running app, its bundled key, and a scratch dir under `$TMPDIR`.
    public static func forRunningApp() -> UpdateInstaller {
        UpdateInstaller(publicKey: bundledPublicKey(), appURL: Bundle.main.bundleURL,
                        workDir: FileManager.default.temporaryDirectory.appendingPathComponent("GituniaUpdate"))
    }

    /// Missing or empty in dev builds / `swift run` — those can't auto-install.
    public static func bundledPublicKey(_ info: [String: Any]? = Bundle.main.infoDictionary) -> Data? {
        guard let s = info?["GituniaUpdatePublicKey"] as? String, !s.isEmpty else { return nil }
        return Data(base64Encoded: s)
    }

    public static let defaultDownload: @Sendable (URL) async throws -> URL = { url in
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.failed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        return file
    }

    public var hasPublicKey: Bool { publicKey != nil }
    public var canReplaceApp: Bool { Self.canReplace(appURL: appURL) }

    public static func verify(dmg: URL, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// The requirement a replacement must meet: the running app's designated requirement, or nil when
    /// there's nothing stable to pin. macOS ties folder-access grants to that requirement, so an update
    /// meeting it keeps them. Ad-hoc's is its own cdhash (printed commented out, `# designated => cdhash
    /// H"…"`) and an unsigned app has none; nil there lets the ad-hoc → certificate transition through.
    public static func pinnedRequirement(codesignDisplay output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("designated => ") {
            let requirement = line.dropFirst("designated => ".count)
            return requirement.contains("cdhash") ? nil : String(requirement)
        }
        return nil
    }

    /// `codesign -d -r-` on the running app; any failure means "nothing pinned", never "refuse".
    public static let runningAppRequirement: @Sendable (URL) async -> String? = { app in
        guard let r = try? await ProcessRunner.run(executable: "/usr/bin/codesign", arguments: ["-d", "-r-", app.path]) else { return nil }
        return pinnedRequirement(codesignDisplay: r.stdout + "\n" + r.stderr)
    }

    /// Any Apple Developer ID signature for `identifier` — the one other signer an update may carry,
    /// so moving from the self-signed certificate to a paid one later needs no manual download.
    /// The Ed25519 DMG signature is what proves an update is ours; the pin only keeps folder-access
    /// grants from resetting on every update.
    public static func developerIDRequirement(identifier: String) -> String {
        #"identifier "\#(identifier)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
    }

    /// Whether `app`'s signature is valid and meets `requirement`.
    public static func satisfies(_ app: URL, requirement: String) async -> Bool {
        (try? await run("/usr/bin/codesign", ["--verify", "--strict", "-R", "=" + requirement, app.path])) != nil
    }

    /// A read-only volume (running straight from the dmg) or a Gatekeeper-translocated copy can't
    /// be swapped in place, and neither can a bundle whose folder we can't write.
    public static func canReplace(appURL: URL) -> Bool {
        let path = appURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    public func prepare(_ release: ReleaseInfo) async throws -> PreparedUpdate {
        guard let publicKey else { throw UpdateInstallError.noPublicKey }
        guard let dmgURL = release.dmgURL, let sigURL = release.signatureURL else { throw UpdateInstallError.noSignature }
        let fm = FileManager.default
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        do {
            let dmg = workDir.appendingPathComponent("update.dmg")
            try fm.moveItem(at: try await download(dmgURL), to: dmg)
            let sigText = String(decoding: try Data(contentsOf: try await download(sigURL)), as: UTF8.self)
            guard let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw UpdateInstallError.noSignature
            }
            guard Self.verify(dmg: dmg, signature: signature, publicKey: publicKey) else { throw UpdateInstallError.badSignature }

            let mnt = workDir.appendingPathComponent("mnt"), app = workDir.appendingPathComponent("Gitunia.app")
            try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt.path, dmg.path])
            var copyError: (any Error)?
            do { try await Self.run("/usr/bin/ditto", [mnt.appendingPathComponent("Gitunia.app").path, app.path]) } catch { copyError = error }
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mnt.path, "-force"])
            if let copyError { throw copyError }

            let plist = try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            guard plist?["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
                  plist?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateInstallError.wrongBundle }
            if let requirement = await pinnedRequirement(appURL),
               !(await Self.satisfies(app, requirement: requirement)),
               !(await Self.satisfies(app, requirement: Self.developerIDRequirement(identifier: Self.bundleIdentifier))) {
                throw UpdateInstallError.differentSigner
            }
            try await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            try? fm.removeItem(at: dmg)
            return PreparedUpdate(version: release.version, bundleURL: app)
        } catch {
            try? fm.removeItem(at: workDir)
            throw error
        }
    }

    /// Launches the swap script detached; the caller then quits the app.
    public func install(_ prepared: PreparedUpdate, relaunch: Bool) throws {
        let script = workDir.appendingPathComponent("install.sh")
        try Self.installScript(pid: ProcessInfo.processInfo.processIdentifier, appURL: appURL,
                               newApp: prepared.bundleURL, workDir: workDir, relaunch: relaunch)
            .write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()   // not waited on: it outlives us, polling our PID
    }

    /// Pure so tests can check it without running it. On timeout it gives up rather than replace
    /// a running app.
    public static func installScript(pid: Int32, appURL: URL, newApp: URL, workDir: URL, relaunch: Bool) -> String {
        let app = shellQuote(appURL.path), new = shellQuote(newApp.path), work = shellQuote(workDir.path)
        let old = shellQuote(workDir.appendingPathComponent("old.app").path)
        return """
        #!/bin/sh
        # ponytail: no admin-privilege escalation — apps in a non-writable location fall back to the manual download.
        exec >>\(shellQuote(workDir.appendingPathComponent("update.log").path)) 2>&1
        i=0
        while kill -0 \(pid) 2>/dev/null; do
          i=$((i+1)); [ "$i" -ge 150 ] && { echo "timed out waiting for \(pid)"; exit 1; }
          sleep 0.2
        done
        rm -rf \(old)
        mv \(app) \(old) || exit 1
        if ! mv \(new) \(app); then echo "install failed, restoring"; mv \(old) \(app); fi
        \(relaunch ? "open \(app)" : ":")
        find \(work) -mindepth 1 -maxdepth 1 ! -name update.log -exec rm -rf {} +

        """
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    private static func run(_ executable: String, _ args: [String]) async throws -> ProcessResult {
        let r = try await ProcessRunner.run(executable: executable, arguments: args)
        guard r.exitCode == 0 else {
            throw UpdateInstallError.failed("\((executable as NSString).lastPathComponent) failed: \(r.stderr)")
        }
        return r
    }
}
