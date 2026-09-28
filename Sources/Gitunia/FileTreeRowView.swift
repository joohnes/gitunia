import SwiftUI
import GituniaCore

/// Renders one row of a flattened file tree (`FileTree.flatten`) — indentation by depth, a
/// chevron button that toggles collapse on directory rows, folder icon + name. File rows delegate
/// to `fileLabel` so each caller keeps its own look (`ChangeRow`'s status letter in `ChangesView`,
/// a plain filename `Text` in `CommitDiffView`) without either view needing its own recursive,
/// `AnyView`-erased tree renderer — see `FileTree.flatten`'s doc comment for why that recursion
/// (nested `DisclosureGroup`s inside a `List`) was the bug.
struct FileTreeRowView<Payload: Sendable & Equatable, FileLabel: View>: View {
    let row: FileTreeRow<Payload>
    let onToggle: (String) -> Void
    @ViewBuilder let fileLabel: (Payload, String) -> FileLabel

    private let indentUnit: CGFloat = 16

    var body: some View {
        switch row.kind {
        case .directory(let name, _, let isExpanded):
            // The whole row toggles, not just the chevron glyph — a bigger, easier target than a
            // 10pt icon, and it's what `Button`'s hit-testing already gives us for free by wrapping
            // the full label instead of just the image.
            Button { onToggle(row.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Label(name, systemImage: "folder").font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tree.directory.\(row.id)")
            .padding(.leading, CGFloat(row.depth) * indentUnit)
        case .file(let payload, let name):
            fileLabel(payload, name)
                .padding(.leading, CGFloat(row.depth) * indentUnit + 14)
        }
    }
}
