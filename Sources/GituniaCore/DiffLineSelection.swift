import Foundation

/// Click/shift-click/⌘-click rules for selecting diff lines. Only added/removed lines of
/// unclipped hunks are selectable (context lines can't be staged on their own).
public enum DiffLineSelection {
    public static func isSelectable(_ ref: DiffLineRef, in diff: FileDiff) -> Bool {
        guard diff.hunks.indices.contains(ref.hunk) else { return false }
        let hunk = diff.hunks[ref.hunk]
        return !hunk.isClipped && hunk.lines.indices.contains(ref.line) && hunk.lines[ref.line].kind != .context
    }

    /// Plain click selects just `ref` (or clears, if it was the only selected line); `extend`
    /// (shift) selects every selectable line between the anchor and `ref`; `toggle` (⌘) flips
    /// `ref` alone. Returns the new selection and anchor.
    public static func click(_ ref: DiffLineRef, extend: Bool, toggle: Bool, selection: Set<DiffLineRef>,
                             anchor: DiffLineRef?, in diff: FileDiff) -> (selection: Set<DiffLineRef>, anchor: DiffLineRef?) {
        guard isSelectable(ref, in: diff) else { return (selection, anchor) }
        if extend, let anchor {
            let (lo, hi) = (min(anchor, ref), max(anchor, ref))
            var range = Set<DiffLineRef>()
            for h in lo.hunk...hi.hunk {
                for i in diff.hunks[h].lines.indices {
                    let r = DiffLineRef(hunk: h, line: i)
                    if lo <= r && r <= hi && isSelectable(r, in: diff) { range.insert(r) }
                }
            }
            return (range, anchor)
        }
        if toggle {
            var s = selection
            if s.remove(ref) == nil { s.insert(ref) }
            return (s, ref)
        }
        return selection == [ref] ? ([], nil) : ([ref], ref)
    }
}
