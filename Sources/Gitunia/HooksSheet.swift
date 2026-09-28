import SwiftUI
import AppKit
import GituniaCore

/// "Hooks…" — every hook git would run in this repo (plus disabled ones and samples), so a hook an
/// agent installed is visible. Enable/disable toggles the executable bit; nothing is deleted.
struct HooksSheet: View {
    var repo: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    /// `nil` = not loaded yet.
    @State private var hooks: [GitHook]?
    @State private var location: (url: URL, source: HookSource)?
    @State private var selection: GitHook.ID?
    @State private var contents: String?
    @State private var showSamples = false
    @State private var errorText: String?

    /// `hooks` preloads the list (render tests); otherwise it's loaded on appear.
    init(repo: RepositoryStore, hooks: [GitHook]? = nil, selection: GitHook.ID? = nil) {
        self.repo = repo
        _hooks = State(initialValue: hooks)
        _selection = State(initialValue: selection)
    }

    private var all: [GitHook] { hooks ?? [] }
    private var selected: GitHook? { all.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hooks — \(repo.repo.name)").font(.headline)
            list
            contentsView
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .top) {
                Text(footer).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 580)
        .task {
            location = await repo.hooksDirectory()
            if hooks == nil { hooks = await repo.hooks() }
        }
        .task(id: selection) {
            contents = nil
            if let selected { contents = await repo.hookContents(selected) }
        }
    }

    @ViewBuilder private var list: some View {
        let real = all.filter { !$0.isSample }
        let samples = all.filter(\.isSample)
        if hooks == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        } else {
            List(selection: $selection) {
                if real.isEmpty {
                    Text("No hooks installed.").foregroundStyle(.secondary)
                }
                ForEach(Dictionary(grouping: real, by: \.source).sorted { Self.title($0.key) < Self.title($1.key) }, id: \.key) { source, items in
                    Section(Self.title(source)) {
                        ForEach(items) { row($0) }
                    }
                }
                if !samples.isEmpty {
                    Section {
                        DisclosureGroup("Samples (\(samples.count))", isExpanded: $showSamples) {
                            ForEach(samples) { row($0) }
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 240)
        }
    }

    private func row(_ hook: GitHook) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hook.name).font(.system(.body, design: .monospaced))
                    .foregroundStyle(hook.isActive ? .primary : .secondary)
                Text(hook.firstLine ?? "(empty)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hook.isSample {
                Text("never runs").font(.caption).foregroundStyle(.tertiary)
            } else {
                Toggle("Enabled", isOn: Binding(get: { hook.isExecutable }, set: { on in
                    Task {
                        errorText = await repo.setHookEnabled(hook, on).map { "Couldn't change \(hook.name): \($0.localizedDescription)" }
                        hooks = repo.gitHooks
                    }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(hook.isExecutable ? "Git runs this hook — turn off to clear its executable bit" : "Not executable — git skips it")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([hook.path])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .tag(hook.id)
    }

    @ViewBuilder private var contentsView: some View {
        Group {
            if selected == nil {
                Text("Select a hook to see its contents.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(Self.highlighted(contents ?? "", language: Self.language(selected?.firstLine)))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private var footer: String {
        guard let location else { return "Git runs only executable hooks; *.sample files never run." }
        let path = (location.url.path as NSString).abbreviatingWithTildeInPath
        switch location.source {
        case .repo:
            return "Hooks directory: \(path) (.git/hooks — core.hooksPath is not set). Git runs only executable, non-.sample files."
        case .hooksPath(let raw):
            return "core.hooksPath = \(raw) (this repo's config) → \(path). It replaces .git/hooks entirely."
        case .globalHooksPath:
            return "core.hooksPath from global git config → \(path). It replaces .git/hooks for every repository on this Mac."
        }
    }

    static func title(_ source: HookSource) -> String {
        switch source {
        case .repo: ".git/hooks"
        case .hooksPath(let raw): "core.hooksPath (\(raw))"
        case .globalHooksPath: "Global core.hooksPath"
        }
    }

    /// Picks a highlighter from the shebang; shell is the common case.
    static func language(_ shebang: String?) -> SyntaxLanguage {
        let s = shebang ?? ""
        if s.contains("python") { return .python }
        if s.contains("node") { return .javascript }
        if s.contains("ruby") { return .ruby }
        return .shell
    }

    /// `SyntaxHighlighter` is single-line, so tokenize per line.
    static func highlighted(_ text: String, language: SyntaxLanguage) -> AttributedString {
        var result = AttributedString()
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { result.append(AttributedString("\n")) }
            let line = String(line)
            for token in SyntaxHighlighter.tokens(in: line, language: language) {
                var piece = AttributedString(String(line[token.range]))
                piece.foregroundColor = Theme.syntax(token.kind)
                result.append(piece)
            }
        }
        return result
    }
}
