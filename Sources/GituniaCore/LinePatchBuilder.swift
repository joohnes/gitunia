import Foundation

/// One line of a `FileDiff`: index into `hunks`, then into that hunk's `lines`.
public struct DiffLineRef: Hashable, Comparable, Sendable {
    public let hunk: Int
    public let line: Int
    public init(hunk: Int, line: Int) { self.hunk = hunk; self.line = line }
    public static func < (a: Self, b: Self) -> Bool { (a.hunk, a.line) < (b.hunk, b.line) }
}

/// Line-level partial patches ("stage/unstage/discard these lines").
///
/// `reverse: false` — the patch is applied forward onto the diff's **old** side (staging an
/// unstaged diff: `git apply --cached`). The old side must stay exactly as it is, so:
/// selected `+` → `+`, unselected `+` → dropped, selected `-` → `-`, unselected `-` → context.
///
/// `reverse: true` — the patch is applied with `--reverse` onto the diff's **new** side
/// (unstaging a staged diff: `git apply --cached --reverse`; discarding an unstaged diff:
/// `git apply --reverse`). Now the new side must stay intact, so the roles invert:
/// selected `+` → `+`, unselected `+` → context, selected `-` → `-`, unselected `-` → dropped.
///
/// Unselected lines are converted *in place* (no reordering). Headers are recomputed from the
/// emitted lines; the start of the untouched side is kept, the other side's start is derived from
/// it plus the running delta of earlier hunks in the same patch.
///
/// "\ No newline at end of file": each output line knows whether it lacks a newline on its side
/// (`DiffLine.noNewline`), and the marker is emitted only where that line is still the *last*
/// line of that side of the patch. A context line whose two sides then disagree (it was the old
/// file's unterminated last line, but selected `+` lines now follow it) is split into
/// `-x` + marker / `+x` — exactly what git itself emits when appending to such a file.
extension PatchBuilder {
    public static func patch(path: String, hunks: [Hunk], selected: Set<DiffLineRef>, reverse: Bool) -> String? {
        var body = ""
        var delta = 0
        for (h, hunk) in hunks.enumerated() {
            guard !hunk.isClipped, let header = HunkHeader(hunk.header) else { continue }
            let ops = operations(hunk, hunk: h, selected: selected, reverse: reverse)
            guard ops.contains(where: { $0.kind != .context }) else { continue }
            let (lines, oldCount, newCount) = render(ops)
            guard !isNoOp(ops) else { continue }
            let (keptStart, keptCount) = reverse ? (header.newStart, header.newCount) : (header.oldStart, header.oldCount)
            let firstLine = keptCount == 0 ? keptStart + 1 : keptStart
            let otherCount = reverse ? oldCount : newCount
            let otherStart = (otherCount == 0 ? firstLine - 1 : firstLine) + delta
            let (oS, oC, nS, nC) = reverse
                ? (otherStart, oldCount, keptStart, newCount)
                : (keptStart, oldCount, otherStart, newCount)
            delta += reverse ? oldCount - newCount : newCount - oldCount
            body += "@@ -\(oS),\(oC) +\(nS),\(nC) @@\n" + lines
        }
        guard !body.isEmpty else { return nil }
        return "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + body
    }

    private struct Op {
        let kind: DiffLine.Kind
        let text: String
        let noNewline: Bool
    }

    private static func operations(_ hunk: Hunk, hunk h: Int, selected: Set<DiffLineRef>, reverse: Bool) -> [Op] {
        hunk.lines.enumerated().compactMap { i, line in
            let isSelected = selected.contains(DiffLineRef(hunk: h, line: i))
            let kind: DiffLine.Kind?
            switch line.kind {
            case .context: kind = .context
            case .added: kind = isSelected ? .added : (reverse ? .context : nil)
            case .removed: kind = isSelected ? .removed : (reverse ? nil : .context)
            }
            return kind.map { Op(kind: $0, text: line.text, noNewline: line.noNewline) }
        }
    }

    /// Emits the hunk body and returns (text, oldCount, newCount).
    private static func render(_ ops: [Op]) -> (String, Int, Int) {
        let lastOld = ops.lastIndex { $0.kind != .added }
        let lastNew = ops.lastIndex { $0.kind != .removed }
        let marker = "\\ No newline at end of file\n"
        var out = ""
        var oldCount = 0, newCount = 0
        for (i, op) in ops.enumerated() {
            let oldNoNL = i == lastOld && op.noNewline
            let newNoNL = i == lastNew && op.noNewline
            switch op.kind {
            case .context where oldNoNL != newNoNL:
                out += "-\(op.text)\n" + (oldNoNL ? marker : "") + "+\(op.text)\n" + (newNoNL ? marker : "")
                oldCount += 1; newCount += 1
            case .context:
                out += " \(op.text)\n" + (oldNoNL ? marker : "")
                oldCount += 1; newCount += 1
            case .removed:
                out += "-\(op.text)\n" + (oldNoNL ? marker : "")
                oldCount += 1
            case .added:
                out += "+\(op.text)\n" + (newNoNL ? marker : "")
                newCount += 1
            }
        }
        return (out, oldCount, newCount)
    }

    /// Both sides identical (e.g. only the "-x / +x" newline pair selected while later lines keep
    /// x from being last) — git would accept it and change nothing, so it's skipped.
    private static func isNoOp(_ ops: [Op]) -> Bool {
        func side(_ keep: DiffLine.Kind) -> [String] {
            let kept = ops.filter { $0.kind != keep }
            return kept.enumerated().map { i, op in op.text + (i == kept.count - 1 && op.noNewline ? "" : "\n") }
        }
        return side(.added) == side(.removed)
    }
}

/// "@@ -a[,b] +c[,d] @@ …" — a missing count means 1.
struct HunkHeader {
    let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int

    init?(_ header: String) {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",").map { Int($0) }
            guard let start = nums.first ?? nil else { return nil }
            if nums.count == 1 { return (start, 1) }
            guard nums.count == 2, let count = nums[1] else { return nil }
            return (start, count)
        }
        guard let o = range(parts[1]), let n = range(parts[2]) else { return nil }
        (oldStart, oldCount, newStart, newCount) = (o.0, o.1, n.0, n.1)
    }
}
