import SwiftUI
import GituniaCore

/// Searchable branch list shown in a popover — the toolbar's branch switcher and the History /
/// Compare pickers. Replaces `Menu`s and `Picker`s that built one `NSMenuItem` (the toolbar: a
/// whole submenu) per branch, eagerly, on every repository change — thousands of branches stalled
/// the UI. `List` only builds the rows on screen.
struct BranchListPopover<RowMenu: View>: View {
    /// A non-branch row (detached HEAD, a worktree). `value` is what `onPick` receives.
    struct Extra: Equatable {
        let value: String
        let label: String
    }

    let branches: [BranchInfo]
    /// Checkmarked. With `selectionIsPickable == false` it's also inert — the checked-out branch
    /// in the toolbar, where "switch to it" means nothing.
    var selection: String?
    var selectionIsPickable = true
    /// Rows above Local (detached HEAD) and a titled section below Remote (worktrees).
    var leading: [Extra] = []
    var trailing: (title: String, entries: [Extra]) = ("", [])
    let onPick: (String) -> Void
    /// Per-branch context menu; nil attaches none.
    var rowMenu: ((BranchInfo) -> RowMenu)?

    @State private var query = ""
    @State private var groups: [Group] = []
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable, Equatable {
        /// Section-qualified, so a value listed twice (never, in practice) can't collide in `List`.
        let id: String
        let value: String
        let label: String
        let branch: BranchInfo?
    }

    private struct Group: Identifiable, Equatable {
        let id: String
        let items: [Item]
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search branches…", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($searchFocused)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.return) {
                    if let item = pickable.first(where: { $0.id == highlighted }) { onPick(item.value) }
                    return .handled
                }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            if groups.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding().frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groups) { group in
                            if group.id.isEmpty {
                                ForEach(group.items) { item in row(item) }
                            } else {
                                Section(group.id) {
                                    ForEach(group.items) { item in row(item) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 340, height: 420)
        .onChange(of: query, initial: true) { rebuild() }
        .onChange(of: branches) { rebuild() }
        // Same one-turn delay as `CommandPalette`: focusing in `.onAppear` loses to the field's
        // first attach.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let isSelected = item.value == selection
        let label = HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.brand)
                .opacity(isSelected ? 1 : 0)
            Text(item.label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isPickable(item) { onPick(item.value) } }
        .listRowSeparator(.hidden)
        .listRowBackground(
            item.id == highlighted ? Theme.brand.opacity(0.18).clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 6) : nil
        )
        if let rowMenu, let branch = item.branch {
            label.contextMenu { rowMenu(branch) }
        } else {
            label
        }
    }

    private func isPickable(_ item: Item) -> Bool {
        selectionIsPickable || item.value != selection
    }

    private var pickable: [Item] {
        groups.flatMap(\.items).filter(isPickable)
    }

    private func move(_ delta: Int) {
        let items = pickable
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == highlighted } ?? -delta
        highlighted = items[min(max(index + delta, 0), items.count - 1)].id
    }

    /// Runs on query and branch-list changes only, so moving the highlight never re-ranks. Local
    /// leads with the current branch, then the pinned defaults, then git's order; an empty query
    /// keeps that order (`FuzzyMatch.rank` returns it untouched).
    private func rebuild() {
        let local = branches.localPinnedFirst
        let ordered = (local.pinned + local.rest).filter(\.isCurrent)
            + local.pinned.filter { !$0.isCurrent } + local.rest.filter { !$0.isCurrent }
        let branchItems = { (section: String, list: [BranchInfo]) in
            list.map { Item(id: "\(section):\($0.name)", value: $0.name, label: $0.name, branch: $0) }
        }
        let extraItems = { (section: String, list: [Extra]) in
            list.map { Item(id: "\(section):\($0.value)", value: $0.value, label: $0.label, branch: nil) }
        }
        let all = [
            Group(id: "", items: extraItems("", leading)),
            Group(id: "Local", items: branchItems("Local", ordered)),
            Group(id: "Remote", items: branchItems("Remote", branches.filter(\.isRemote))),
            Group(id: trailing.title, items: extraItems(trailing.title, trailing.entries)),
        ]
        groups = all.compactMap { group in
            let ranked = FuzzyMatch.rank(group.items, query: query, key: \.label)
            return ranked.isEmpty ? nil : Group(id: group.id, items: ranked)
        }
        highlighted = pickable.first?.id
    }
}

extension BranchListPopover where RowMenu == EmptyView {
    init(branches: [BranchInfo], selection: String?, leading: [Extra] = [],
         trailing: (title: String, entries: [Extra]) = ("", []), onPick: @escaping (String) -> Void) {
        self.init(branches: branches, selection: selection, leading: leading, trailing: trailing, onPick: onPick, rowMenu: nil)
    }
}

/// Stands in for a branch `Picker` (History, Compare): a pop-up-style button that opens
/// `BranchListPopover` and closes it on pick.
struct BranchPickerButton: View {
    let title: String
    let branches: [BranchInfo]
    var selection: String?
    var leading: [BranchListPopover<EmptyView>.Extra] = []
    var trailing: (title: String, entries: [BranchListPopover<EmptyView>.Extra]) = ("", [])
    let onPick: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BranchListPopover(branches: branches, selection: selection, leading: leading, trailing: trailing) { value in
                isPresented = false
                onPick(value)
            }
        }
    }
}
