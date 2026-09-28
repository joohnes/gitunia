import Foundation

/// File content for previewing (Quick Look/`NSImage`) at a given ref, as a URL on disk — Quick
/// Look reads files, not `Data`. See `docs/file-preview-plan.md` step 2.
extension RepositoryStore {
    private static let previewCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("gitunia-preview", isDirectory: true)

    /// `git show <ref>:<path>`, or nil when the path doesn't exist at that ref.
    public func blobContent(path: String, at ref: String) async -> Data? {
        try? await git.runData(["show", "\(ref):\(path)"], in: url)
    }

    /// A URL Quick Look/`NSImage` can read for `path` at `ref`, or the working-tree file when
    /// `ref` is nil. For a ref, the blob is written to
    /// `<tmp>/gitunia-preview/<blob OID>/<basename>` — keyed by content, not ref, so identical
    /// content across commits is written once — and reused if already there. Nil when the path
    /// doesn't exist at that ref (or on disk, for `ref == nil`).
    public func previewFile(path: String, at ref: String?) async -> URL? {
        guard let ref else {
            let fileURL = url.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }
        guard let oid = try? await git.run(["rev-parse", "\(ref):\(path)"], in: url).trimmingCharacters(in: .whitespacesAndNewlines),
              !oid.isEmpty else { return nil }
        let dest = Self.previewCacheDir.appendingPathComponent(oid).appendingPathComponent((path as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let data = await blobContent(path: path, at: ref) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            return dest
        } catch {
            return nil
        }
    }

    public func previewFileForHEAD(path: String) async -> URL? {
        await previewFile(path: path, at: "HEAD")
    }
}
