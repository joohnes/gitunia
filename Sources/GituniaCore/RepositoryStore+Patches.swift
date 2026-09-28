import Foundation

/// What `git apply --check` says about a patch before anything touches the working tree.
public struct PatchCheck: Equatable, Sendable {
    public var applies: Bool
    /// "Applies cleanly — 2 files: a, b", or git's error text.
    public var message: String
    /// A `git format-patch` mailbox (has From/Subject headers), so `git am` can recreate the commits.
    public var isMailbox: Bool
    public var touchedFiles: [String]
    public init(applies: Bool, message: String, isMailbox: Bool, touchedFiles: [String]) {
        self.applies = applies; self.message = message; self.isMailbox = isMailbox; self.touchedFiles = touchedFiles
    }

    /// `git format-patch` output starts with `From <sha> Mon Sep 17 00:00:00 2001` (a fixed date).
    public static func isMailbox(_ text: String) -> Bool {
        let first = text.drop(while: \.isNewline).prefix(while: { !$0.isNewline })
        let parts = first.split(separator: " ", maxSplits: 2)
        return parts.count == 3 && parts[0] == "From" && parts[1].count >= 40
            && parts[1].allSatisfy(\.isHexDigit) && parts[2] == "Mon Sep 17 00:00:00 2001"
    }
}

/// Patch out (format-patch / diff) and patch in (apply / am).
extension RepositoryStore {
    /// git's own `format-patch` file-name rule: ASCII alnum, `.` and `_` kept (case kept too, like
    /// git), every other run → one `-`, repeated dots collapsed, trailing `.`/`-` trimmed, then cut
    /// to 52 bytes — verified against `git format-patch -o` output.
    public static func patchFileName(subject: String, number: Int = 1) -> String {
        var out: [UInt8] = []
        var space = 2 // 2 = start: leading junk adds no dash
        var lastWasDot = false
        for byte in subject.utf8 {
            let isTitle = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
            guard isTitle else { space |= 1; lastWasDot = false; continue }
            if byte == UInt8(ascii: "."), lastWasDot, space == 0 { continue }
            if space == 1 { out.append(UInt8(ascii: "-")) }
            space = 0
            out.append(byte)
            lastWasDot = byte == UInt8(ascii: ".")
        }
        while let last = out.last, last == UInt8(ascii: ".") || last == UInt8(ascii: "-") { out.removeLast() }
        let slug = String(decoding: out.prefix(52), as: UTF8.self)
        return String(format: "%04d-", number) + slug + ".patch"
    }

    /// One `git format-patch --stdout -1` per commit, in the order given, named like git would.
    public func formatPatch(_ hashes: [String]) async -> [(name: String, contents: String)] {
        var result: [(name: String, contents: String)] = []
        for (i, hash) in hashes.enumerated() {
            guard let contents = try? await git.run(["format-patch", "--stdout", "-1", hash], in: url) else { continue }
            let subject = (try? await git.run(["log", "-1", "--format=%s", hash], in: url))?
                .trimmingCharacters(in: .newlines) ?? ""
            result.append((Self.patchFileName(subject: subject, number: i + 1), contents))
        }
        return result
    }

    /// The full working-tree (or staged) diff — never truncated, unlike the AI/display paths.
    public func diffPatch(staged: Bool) async -> String {
        (try? await git.run(["diff", "--binary"] + (staged ? ["--cached"] : []), in: url)) ?? ""
    }

    public func checkPatch(_ text: String) async -> PatchCheck {
        let mailbox = PatchCheck.isMailbox(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PatchCheck(applies: false, message: "", isMailbox: false, touchedFiles: [])
        }
        do {
            let out = try await git.run(["apply", "--check", "--numstat", "-"], in: url, stdin: text)
            let files = out.split(separator: "\n").compactMap { line -> String? in
                let cols = line.split(separator: "\t", maxSplits: 2)
                return cols.count == 3 ? String(cols[2]) : nil
            }
            guard !files.isEmpty else {
                return PatchCheck(applies: false, message: "No changes found in this patch", isMailbox: mailbox, touchedFiles: [])
            }
            let noun = files.count == 1 ? "file" : "files"
            return PatchCheck(applies: true, message: "Applies cleanly — \(files.count) \(noun): \(files.joined(separator: ", "))",
                              isMailbox: mailbox, touchedFiles: files)
        } catch let e as GitError {
            return PatchCheck(applies: false, message: e.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                              isMailbox: mailbox, touchedFiles: [])
        } catch {
            return PatchCheck(applies: false, message: error.localizedDescription, isMailbox: mailbox, touchedFiles: [])
        }
    }

    /// `git am` (recreates the commits, author kept) for a mailbox patch when `asCommits`, else
    /// `git apply` onto the working tree only so the user reviews and stages as usual (`--3way`
    /// stages what it merges — git's rule). A failed `am` is aborted so the repo never sits mid-am.
    public func applyPatch(_ text: String, asCommits: Bool, threeWay: Bool) async -> GitError? {
        if let op = operation {
            return GitError(args: ["apply"], exitCode: -1, stderr: "A \(op.label) is in progress — finish or abort it first.")
        }
        let am = asCommits && PatchCheck.isMailbox(text)
        let args = (am ? ["am"] : ["apply"]) + (threeWay ? ["--3way"] : []) + (am ? [] : ["-"])
        if await perform(args, stdin: text) { return nil }
        let error = lastError
        if am {
            _ = try? await git.run(["am", "--abort"], in: url)
            await refreshStatus()
            lastError = error
        }
        return error
    }
}
