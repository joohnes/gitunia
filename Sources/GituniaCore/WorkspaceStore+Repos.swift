import Foundation

/// Workspace-level repository management: clone and init into a chosen parent folder, and lookup
/// of sidebar repositories by path (for the Submodules/Worktrees sheets' Open/Select).
extension WorkspaceStore {
    public enum RepoCreationError: LocalizedError {
        case invalidName(String)
        public var errorDescription: String? {
            switch self {
            case .invalidName(let reason): reason
            }
        }
    }

    private func destination(for name: String, in parent: URL) throws -> URL {
        if let reason = NewRepoName.validate(name, in: parent) { throw RepoCreationError.invalidName(reason) }
        return parent.appendingPathComponent(name)
    }

    /// `git clone --progress -- <source> <parent>/<name>`, reporting parsed progress, then adds the
    /// clone to the workspace. Cancelling the calling task kills git; the destination is then removed
    /// if it exists — safe because `destination(for:in:)` already refused a pre-existing folder, so anything there is the clone's.
    /// Errors are `GitError`s with credentials redacted from both the args and git's stderr.
    @discardableResult
    public func cloneRepository(from source: String, named name: String, in parent: URL,
                                options: CloneOptions = CloneOptions(),
                                onProgress: (CloneProgress) -> Void = { _ in }) async throws -> URL {
        let dest = try destination(for: name, in: parent)
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        async let run = Self.runClone(source: source, dest: dest, options: options, continuation: continuation)
        var parser = CloneProgressParser()
        for await chunk in stream {
            if let progress = parser.feed(chunk) { onProgress(progress) }
        }
        let result: ProcessResult
        do {
            result = try await run
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw GitError(args: ["clone", RepoURL.redactingCredentials(source), name], exitCode: result.exitCode,
                           stderr: RepoURL.redactingCredentials(result.stderr))
        }
        await didCreateRepository(at: dest, parent: parent)
        return dest
    }

    private nonisolated static func runClone(source: String, dest: URL, options: CloneOptions,
                                             continuation: AsyncStream<String>.Continuation) async throws -> ProcessResult {
        defer { continuation.finish() }
        return try await StreamingProcess.run(
            executable: GitRunner.executable,
            arguments: ["clone", "--progress"] + options.arguments + ["--", source, dest.path],
            currentDirectory: dest.deletingLastPathComponent(),
            environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
            onStderr: { continuation.yield($0) }
        )
    }

    /// `git init -b master <parent>/<name>`, added to the workspace — nothing else (no initial commit: the human keeps
    /// history writes). `-b` exists since git 2.28; the installed git is 2.50, so no fallback.
    @discardableResult
    public func initRepository(named name: String, in parent: URL) async throws -> URL {
        let dest = try destination(for: name, in: parent)
        try await GitRunner().run(["init", "-q", "-b", "master", dest.path], in: parent)
        await didCreateRepository(at: dest, parent: parent)
        return dest
    }

    /// A repo created inside a linked folder is already covered by that folder, so rescan instead of
    /// adding a redundant single entry. Falls back to adding it if the scan doesn't show it (e.g. excluded).
    private func didCreateRepository(at url: URL, parent: URL) async {
        app.setLastRepoParent(parent)
        let path = WorkspaceFile.standardize(url.path)
        if file.folders.contains(where: { path.hasPrefix(WorkspaceFile.standardize($0.path) + "/") }) {
            await refreshAll()
            if let store = repository(atPath: path) { select(store); return }
        }
        _ = try? await addRepository(url)
    }

    /// The sidebar repository at `path`, comparing symlink-resolved paths — git reports
    /// `/private/var/...` where the scanner saw `/var/...`.
    public func repository(atPath path: String) -> RepositoryStore? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return repositories.first { $0.url.resolvingSymlinksInPath().path == target }
    }

    /// Selects `store`, clearing a scope/search that would hide it.
    public func select(_ store: RepositoryStore) {
        if !visibleRepositories.contains(where: { $0.id == store.id }) {
            scope = .all
            searchQuery = ""
        }
        selectedRepoID = store.id
    }

    /// ⌘1…⌘9: the `index`-th row of the sidebar as displayed (worktrees nested). No-op when out of range.
    public func selectRepository(atSidebarIndex index: Int) {
        let rows = Self.sidebarOrder(visibleRepositories)
        guard rows.indices.contains(index) else { return }
        select(rows[index].repo)
    }

    /// Selects the next (or previous) visible repository with uncommitted changes, in sidebar
    /// order, wrapping around. Does nothing when no visible repository has changes.
    public func selectAdjacentChanged(forward: Bool) {
        let list = visibleRepositories
        guard !list.isEmpty else { return }
        let start = list.firstIndex { $0.id == selectedRepoID } ?? (forward ? -1 : list.count)
        let step = forward ? 1 : -1
        for offset in 1...list.count {
            let i = ((start + step * offset) % list.count + list.count) % list.count
            if list[i].repo.hasChanges { select(list[i]); return }
        }
    }
}
