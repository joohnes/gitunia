import SwiftUI
import GituniaCore

/// What `DiffBodyView` may do with a line selection — nil (the default) means lines aren't
/// selectable at all (commit diffs, untracked/deleted files).
struct DiffLineActions {
    enum Op { case stage, unstage, discard }
    let path: String
    /// `[.unstage]` for a staged diff, `[.stage, .discard]` for an unstaged one.
    let ops: [Op]
    let perform: (Op, Set<DiffLineRef>) -> Void
}

/// Floating bar over the diff while lines are selected. Discard is destructive and always asks
/// first, naming the line count and the file.
struct LineSelectionBar: View {
    let count: Int
    let actions: DiffLineActions
    let run: (DiffLineActions.Op) -> Void
    let clear: () -> Void
    @State private var confirmDiscard = false

    private var noun: String { count == 1 ? "line" : "lines" }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(count) \(noun) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            if actions.ops.contains(.stage) {
                Button("Stage Lines (\(count))") { run(.stage) }
                    .buttonStyle(.borderedProminent)
                    .help("Stage the selected lines (s)")
            }
            if actions.ops.contains(.unstage) {
                Button("Unstage Lines (\(count))") { run(.unstage) }
                    .buttonStyle(.borderedProminent)
                    .help("Unstage the selected lines (u)")
            }
            if actions.ops.contains(.discard) {
                Button("Discard Lines (\(count))…", role: .destructive) { confirmDiscard = true }
            }
            Button { clear() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Clear line selection (Esc)")
        }
        .controlSize(.small)
        .tint(Theme.brand)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.brand.opacity(0.6)))
        .padding(.bottom, 14)
        .confirmationDialog("Discard \(count) \(noun) in \(actions.path)?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard \(count) \(noun.capitalized)", role: .destructive) { run(.discard) }
        } message: {
            Text("The selected changes are removed from the working-tree file. This can't be undone.")
        }
    }
}

/// The line-number gutter of a selectable diff line: clickable (shift extends, ⌘ toggles — read
/// from `NSEvent.modifierFlags` by the caller), with a `Theme.brand` bar + tint when selected.
struct GutterSelection: ViewModifier {
    let isSelected: Bool
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        let marked = content
            .background(isSelected ? Theme.brand.opacity(0.35) : .clear)
            .overlay(alignment: .leading) { if isSelected { Theme.brand.frame(width: 3) } }
        if let onTap {
            marked
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .help("Click to select · ⇧-click extends · ⌘-click toggles")
        } else {
            marked
        }
    }
}
