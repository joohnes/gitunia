import SwiftUI
import GituniaCore

struct SettingsView: View {
    var app: AppConfig
    var updates: UpdateCoordinator
    @State private var settings = AppSettings()
    @State private var retryMessage: String?
    @State private var folderMessage: String?
    @State private var needsRestart = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Accent", selection: $settings.accent) {
                    Text("Gitunia orange").tag(AccentChoice.brand)
                    Text("System accent").tag(AccentChoice.system)
                    Text("Custom").tag(customAccent)
                }
                if case .custom = settings.accent {
                    ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                }
                Stepper(autoFetchLabel, value: $settings.autoFetchMinutes, in: 0...120, step: 5)
                Text("Quietly refreshes ahead/behind counts in the background.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Track remote activity (branches, commits, merged pull requests)", isOn: $settings.trackRemoteActivity)
                Text("Needs auto-fetch. Gitunia compares remote branches before and after each fetch and keeps a log you can review in Activity (⌘⇧A).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Editor") {
                Picker("Open files in", selection: $settings.editorBundleID) {
                    Text("System default").tag(String?.none)
                    ForEach(editorOptions) { editor in
                        Text(editor.name).tag(String?.some(editor.bundleID))
                    }
                }
                Button("Choose Application…") { chooseApp() }
            }
            Section {
                Toggle("Show system notifications", isOn: $settings.notificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Commits, new branches and stopped operations in any repository of an open workspace.")
            }
            Section("AI Commit Messages") {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if settings.aiProvider == .ollama {
                    TextField("Ollama model", text: $settings.ollamaModel)
                }
                Stepper("Diff limit: \(settings.diffCharLimit) characters", value: $settings.diffCharLimit, in: 1000...50000, step: 1000)
                Text("Longer diffs are truncated before being sent to the model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Remove agent trailers (Co-Authored-By, Generated-with…) from commit messages", isOn: $settings.stripAgentTrailers)
            } header: {
                Text("Commit Messages")
            } footer: {
                Text("Applied when you commit, amend, or generate a message. The trailers stay in the draft until then.")
            }
            Section {
                Toggle("Stash uncommitted changes automatically when switching branches", isOn: $settings.autoStashOnSwitch)
            } footer: {
                Text("Stashes are labelled `gitunia: <repo> @ <branch> <time>` so you can find and restore them from Recovery.")
            }
            Section {
                // Blank lines are kept while typing; `AgentProfile.matches` ignores them.
                TextField("Agent authors (one pattern per line)", text: Binding(
                    get: { settings.agentProfile.patterns.joined(separator: "\n") },
                    set: { settings.agentProfile.patterns = $0.components(separatedBy: "\n") }), axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Agents")
            } footer: {
                Text("Commits whose author or email contains one of these are counted as agent commits. Wrap a pattern in slashes for a regular expression.")
            }
            Section("Updates") {
                LabeledContent("Gitunia \(updates.currentVersion)") {
                    HStack(spacing: 8) {
                        if updates.isChecking { ProgressView().controlSize(.small) }
                        Button("Check Now") { updates.checkIfDue(force: true) }
                            .disabled(updates.isChecking)
                    }
                }
                if let status = updateStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Check for updates daily", isOn: $settings.checkForUpdates)
                Toggle("Install updates automatically", isOn: $settings.autoInstallUpdates)
                    .disabled(updates.autoInstallBlocker != nil)
                if let blocker = updates.autoInstallBlocker {
                    Text(blocker).font(.caption).foregroundStyle(.secondary)
                }
                if let prepared = updates.prepared {
                    LabeledContent("Update \(prepared.version) downloaded — Restart to install") {
                        Button("Restart") { updates.restartToUpdate() }
                    }
                } else if let update = updates.availableUpdate {
                    LabeledContent("Latest: \(update.version)") {
                        Button("Download") { NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL) }
                        Button("Skip this version") { updates.skip(update.version) }
                    }
                }
            }
            Section("Storage") {
                LabeledContent("Gitunia keeps its settings and activity log in \(app.configStore.fileURL.deletingLastPathComponent().path)") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.configStore.fileURL]) }
                }
                HStack {
                    Button("Change Folder…") { chooseDataFolder() }
                    if let folderMessage { Text(folderMessage).font(.caption).foregroundStyle(.secondary) }
                    if needsRestart { Button("Restart Now") { relaunch() } }
                }
                if usingFallbackLocation {
                    Text("Access to \(AppDataLocation.directory.path) was denied, so Gitunia is using Application Support instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { retryDocuments() }
                        if let retryMessage { Text(retryMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear { settings = app.settings }
        .onChange(of: settings) { if settings != app.settings { app.updateSettings(settings) } }
    }

    /// Result of the last check, shown inline — the check's toasts only appear in workspace windows.
    private var updateStatus: String? {
        guard !updates.isChecking else { return nil }
        if updates.lastCheckFailed { return "Couldn't reach GitHub Releases." }
        let last = app.config.updateState.lastCheck.map { " · checked \($0.formatted(.relative(presentation: .named)))" } ?? ""
        guard let latest = updates.latestKnown else { return last.isEmpty ? nil : "Last" + last }
        return updates.availableUpdate == nil && updates.prepared == nil
            ? "Up to date (latest release \(latest.version))" + last
            : nil
    }

    private var usingFallbackLocation: Bool {
        app.configStore.fileURL.deletingLastPathComponent().standardizedFileURL == AppDataLocation.legacyDirectory.standardizedFileURL
    }

    private func retryDocuments() {
        switch app.retryDocumentsAccess() {
        case .movedLive: retryMessage = "Moved to \(AppDataLocation.directory.path)."
        case .needsRestart: retryMessage = "Access granted — restart Gitunia to finish moving."
        case .stillDenied: retryMessage = "Still denied. Check System Settings → Privacy & Security → Files and Folders."
        }
    }

    private func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = AppDataLocation.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let current = app.configStore.fileURL.deletingLastPathComponent()
        if let error = AppDataLocation.choose(url, current: current) {
            folderMessage = error
            return
        }
        needsRestart = url.standardizedFileURL != current.standardizedFileURL
        folderMessage = needsRestart ? "Gitunia moves its files to \(url.path) on restart." : nil
    }

    /// Quits, then reopens the app once this process is gone — so the new launch only moves files
    /// after this one has finished saving its windows on quit.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private var autoFetchLabel: String {
        settings.autoFetchMinutes == 0 ? "Auto-fetch: Off" : "Auto-fetch: every \(settings.autoFetchMinutes) minutes"
    }

    /// The "Custom" tag must equal the current value to show as selected; picking it fresh starts
    /// from the brand orange.
    private var customAccent: AccentChoice {
        if case .custom = settings.accent { return settings.accent }
        return .custom(red: 0.91, green: 0.39, blue: 0.10)
    }

    private var customColor: Binding<Color> {
        Binding {
            guard case let .custom(r, g, b) = customAccent else { return .accentColor }
            return Color(.sRGB, red: r, green: g, blue: b)
        } set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            settings.accent = .custom(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        }
    }

    private var editorOptions: [Editor] {
        var options = EditorLauncher.installedEditors()
        if let id = settings.editorBundleID, !options.contains(where: { $0.bundleID == id }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            options.append(Editor(name: name.isEmpty ? id : name, bundleID: id))
        }
        return options
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            settings.editorBundleID = id
        }
    }
}
