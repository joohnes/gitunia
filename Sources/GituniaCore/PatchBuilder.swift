import Foundation

/// Builds a minimal unified patch containing one hunk, suitable for `git apply --cached`.
public enum PatchBuilder {
    public static func patch(path: String, hunk: Hunk) -> String {
        var out = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n\(hunk.header)\n"
        for line in hunk.lines {
            switch line.kind {
            case .context: out += " \(line.text)\n"
            case .added: out += "+\(line.text)\n"
            case .removed: out += "-\(line.text)\n"
            }
            if line.noNewline { out += "\\ No newline at end of file\n" }
        }
        return out
    }
}
