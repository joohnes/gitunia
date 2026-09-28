import SwiftUI
import GituniaCore

/// Pure-values content of "Delete Merged Branches…" (rendered directly by the render tests).
struct MergedBranchesSheetContent: View {
    /// `nil` while loading.
    let base: String?
    let isLoading: Bool
    let candidates: [String]
    @Binding var selected: Set<String>
    /// Branches git refused on the last run, with git's first stderr line.
    let refused: [(name: String, reason: String)]
    var onCancel: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Merged Branches").font(.headline)
            Text(base.map { "Local branches fully merged into \($0). Their commits stay reachable from \($0)." }
                 ?? (isLoading ? "Finding merged branches…" : "No base branch found — needs origin/HEAD, main or master."))
                .font(.callout).foregroundStyle(.secondary)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else if candidates.isEmpty {
                Text(base == nil ? "" : "Nothing to clean up.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(candidates, id: \.self) { name in
                    Toggle(isOn: Binding(
                        get: { selected.contains(name) },
                        set: { if $0 { selected.insert(name) } else { selected.remove(name) } }
                    )) {
                        Text(name).font(.system(.body, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 100, maxHeight: 260)
            }
            if !refused.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Git refused:").font(.caption.weight(.semibold))
                    ForEach(refused, id: \.name) { item in
                        Text("\(item.name) — \(item.reason)").font(.caption).lineLimit(2)
                    }
                }
                .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(Self.deleteTitle(count: selected.count), role: .destructive, action: onDelete)
                    .foregroundStyle(.red)
                    .disabled(selected.isEmpty || isLoading)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    static func deleteTitle(count: Int) -> String { "Delete \(count) Branch\(count == 1 ? "" : "es")…" }
}

/// Loads candidates once, all checked; confirms naming every branch; `git branch -d` each and
/// keeps the sheet open listing any git refused.
struct MergedBranchesSheet: View {
    var repo: RepositoryStore
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var base: String?
    @State private var candidates: [String] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var refused: [(name: String, reason: String)] = []
    @State private var confirming = false

    /// Candidate order, filtered to what's still checked.
    private var toDelete: [String] { candidates.filter(selected.contains) }

    var body: some View {
        MergedBranchesSheetContent(
            base: base, isLoading: isLoading, candidates: candidates, selected: $selected, refused: refused,
            onCancel: { dismiss() }, onDelete: { confirming = true }
        )
        .task { await load() }
        .confirmationDialog("Delete \(toDelete.count) merged branch\(toDelete.count == 1 ? "" : "es")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(toDelete.joined(separator: ", ") + "\n\nLocal branches only (remote copies stay). git branch -d — git refuses any it doesn't consider merged.")
        }
    }

    private func load() async {
        isLoading = true
        let found = await repo.mergedBranchCandidates()
        base = found?.base
        candidates = found?.branches ?? []
        selected = Set(candidates)
        isLoading = false
    }

    private func run() async {
        let result = await repo.deleteMergedBranches(toDelete)
        if !result.deleted.isEmpty {
            toasts.post(.success("Deleted \(result.deleted.count) merged branch\(result.deleted.count == 1 ? "" : "es")", detail: repo.repo.name))
        }
        refused = result.refused
        if refused.isEmpty {
            dismiss()
        } else {
            await load()
            // Keep the refused ones visible but unchecked, so a second click doesn't just retry them.
            selected.subtract(refused.map(\.name))
        }
    }
}
