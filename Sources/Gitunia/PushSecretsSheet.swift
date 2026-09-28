import SwiftUI
import GituniaCore

/// Push's secret review (`RemoteOpsCoordinator.pendingPushSecrets`): one row per flagged file with a
/// checkbox; checked files can be excluded from every future Gitunia secret scan of this repo.
struct PushSecretsSheet: View {
    let repoName: String
    let findings: [SecretScanner.Finding]
    var onIgnore: ([String]) -> Void
    var onPush: () -> Void
    var onCancel: () -> Void
    @State private var selected: Set<String> = []
    @State private var ignored: Set<String> = []

    struct FileRow: Identifiable {
        let path: String
        let labels: [String]
        let commits: [String]
        var id: String { path }
    }

    /// Grouped by file in first-seen order (newest commit first, as `git log` lists them).
    static func rows(_ findings: [SecretScanner.Finding]) -> [FileRow] {
        var order: [String] = [], labels: [String: [String]] = [:], commits: [String: [String]] = [:]
        for f in findings {
            if labels[f.path] == nil { order.append(f.path) }
            if !labels[f.path, default: []].contains(f.label) { labels[f.path, default: []].append(f.label) }
            let c = String(f.commitHash.prefix(7))
            if !c.isEmpty, !commits[f.path, default: []].contains(c) { commits[f.path, default: []].append(c) }
        }
        return order.map { FileRow(path: $0, labels: labels[$0] ?? [], commits: commits[$0] ?? []) }
    }

    private var rows: [FileRow] { Self.rows(findings).filter { !ignored.contains($0.path) } }
    /// Path-less rows ("diff too large to scan") can't be excluded.
    private var selectable: [String] { rows.map(\.path).filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unpushed commits contain what look like secrets").font(.title3.bold())
            Text(repoName).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Every flagged file is now excluded.").foregroundStyle(.secondary)
            } else {
                Toggle("Select all", isOn: Binding(
                    get: { !selectable.isEmpty && selectable.allSatisfy(selected.contains) },
                    set: { selected = $0 ? Set(selectable) : [] }))
                    .disabled(selectable.isEmpty)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            Toggle(isOn: Binding(
                                get: { selected.contains(row.path) },
                                set: { if $0 { selected.insert(row.path) } else { selected.remove(row.path) } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.path.isEmpty ? "(whole push)" : row.path)
                                        .font(.system(.callout, design: .monospaced))
                                        .lineLimit(1).truncationMode(.head)
                                    Text((row.labels + (row.commits.isEmpty ? [] : ["in " + row.commits.joined(separator: ", ")])).joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(row.path.isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Button("Don't Check Selected Again") {
                    let paths = selected.filter { !$0.isEmpty }.sorted()
                    onIgnore(paths)
                    ignored.formUnion(paths)
                    selected = []
                }
                .disabled(selected.isEmpty)
                .help("Gitunia stops scanning these files for secrets in this repository")
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(rows.isEmpty ? "Push" : "Push Anyway", role: rows.isEmpty ? nil : .destructive, action: onPush)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
