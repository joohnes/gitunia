import Foundation

/// One row of a directory tree built by `FileTree.build`, generic over the leaf payload — a
/// `FileChange` for `ChangesView`, a `FileDiff` for the commit-history file list.
///
/// `FileTree.build` is called once per logical grouping (`ChangesView`'s Staged/Changes/Untracked
/// sections, or the whole history file list in one call) with a `salt` string unique to that
/// grouping. Every id in the result is baked in at build time from that salt plus path, so two
/// trees built with different salts never collide even over the same paths (a file both staged
/// and unstaged), and ids stay identical across rebuilds with equal content — FSEvents causes
/// frequent rebuilds while an agent writes, and a churning id would collapse the view's
/// expanded/selected state on every refresh.
public indirect enum FileTreeNode<Payload: Sendable & Equatable>: Sendable, Equatable, Identifiable {
    case directory(name: String, path: String, id: String, children: [FileTreeNode<Payload>])
    case file(Payload, path: String, id: String)

    public var id: String {
        switch self {
        case .file(_, _, let id): return id
        case .directory(_, _, let id, _): return id
        }
    }
}

/// One visible row of a flattened tree (`FileTree.flatten`) — what a `List` actually renders.
/// Depth drives indentation; a directory row carries whether it's expanded so the view can draw
/// its chevron without consulting the collapsed set itself.
public struct FileTreeRow<Payload: Sendable & Equatable>: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// `path` is the directory's repo-relative path (post chain-collapsing, so it can span
        /// several path components, e.g. `Sources/Gitunia`) — kept on the row so a context menu
        /// like "Ignore This Folder" can build a real `.gitignore` pattern without having to
        /// reconstruct it from `name` plus ancestor rows.
        case directory(name: String, path: String, isExpanded: Bool)
        case file(Payload, name: String)
    }

    public let id: String
    public let depth: Int
    public let kind: Kind

    /// Public so a view can synthesize a header row (ChangesView's "Lockfiles (N)" group).
    public init(id: String, depth: Int, kind: Kind) {
        self.id = id
        self.depth = depth
        self.kind = kind
    }
}

extension FileTree {
    /// Flattens a tree plus a set of collapsed directory ids into the rows a flat `List` should
    /// render, in display order. A collapsed directory emits its own row and none of its
    /// descendants (recursively — a collapsed directory nested inside another collapsed directory
    /// contributes nothing either way, since its ancestor already stopped recursion). Directories
    /// default to expanded; only an id present in `collapsed` hides its children. An id in
    /// `collapsed` that no longer matches any directory in `nodes` (the tree rebuilt without it)
    /// is simply never consulted — harmless.
    ///
    /// This is the fix for the `List` row-overlap bug: `List` on macOS is `NSTableView`-backed and
    /// keeps row geometry, which breaks when a nested `DisclosureGroup` inside it collapses.
    /// Flattening ahead of time means `List` only ever sees a plain array — collapsing removes
    /// rows from it like any other array mutation, with no nested views to desynchronise.
    public static func flatten<Payload: Sendable & Equatable>(
        _ nodes: [FileTreeNode<Payload>], collapsed: Set<String>, depth: Int = 0
    ) -> [FileTreeRow<Payload>] {
        var rows: [FileTreeRow<Payload>] = []
        for node in nodes {
            switch node {
            case .file(let payload, let path, let id):
                rows.append(FileTreeRow(id: id, depth: depth, kind: .file(payload, name: (path as NSString).lastPathComponent)))
            case .directory(let name, let path, let id, let children):
                let isExpanded = !collapsed.contains(id)
                rows.append(FileTreeRow(id: id, depth: depth, kind: .directory(name: name, path: path, isExpanded: isExpanded)))
                if isExpanded {
                    rows.append(contentsOf: flatten(children, collapsed: collapsed, depth: depth + 1))
                }
            }
        }
        return rows
    }
}

public enum FileTree {
    /// Groups a flat list of items into a directory tree, collapsing any run of directories that
    /// each have exactly one subdirectory and nothing else into a single row (`Sources/Gitunia`
    /// rather than three nested one-child levels). An item at the repository root produces no
    /// directory row at all.
    ///
    /// - Parameters:
    ///   - path: The repo-relative path for an item (`\.path` for both `FileChange` and
    ///     `FileDiff` today).
    ///   - salt: Distinguishes this build's ids from any other tree that might render alongside
    ///     it — e.g. `ChangesView` builds once per section and salts with the section title
    ///     ("Staged", "Changes", "Untracked") so their directory rows never share expand state,
    ///     and the history file list salts with a constant unique to it.
    public static func build<Payload: Sendable & Equatable>(
        from items: [Payload], path: (Payload) -> String, salt: String
    ) -> [FileTreeNode<Payload>] {
        let root = Trie<Payload>()
        for item in items {
            let components = path(item).split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var node = root
            for (index, component) in components.enumerated() {
                let child = node.children[component] ?? Trie<Payload>()
                if index == components.count - 1 { child.item = item }
                node.children[component] = child
                node = child
            }
        }
        return convert(root, path: "", salt: salt)
    }

    private final class Trie<Payload> {
        var children: [String: Trie<Payload>] = [:]
        var item: Payload?
    }

    private static func convert<Payload: Sendable & Equatable>(_ node: Trie<Payload>, path: String, salt: String) -> [FileTreeNode<Payload>] {
        var directories: [FileTreeNode<Payload>] = []
        var files: [FileTreeNode<Payload>] = []
        for (name, child) in node.children {
            // A name can be both: git happily reports `config` (deleted) and `config/app.json`
            // (added) in the same status. Emitting only the file used to drop the whole subtree
            // under it, so those changed files vanished from the tree view entirely.
            if let item = child.item {
                let filePath = joined(path, name)
                files.append(.file(item, path: filePath, id: "\(salt):\(filePath)"))
            }
            if !child.children.isEmpty {
                directories.append(collapsedDirectory(name: name, path: joined(path, name), node: child, salt: salt))
            }
        }
        directories.sort { directoryName($0).localizedCaseInsensitiveCompare(directoryName($1)) == .orderedAscending }
        files.sort { fileSortKey($0).localizedCaseInsensitiveCompare(fileSortKey($1)) == .orderedAscending }
        return directories + files
    }

    /// Walks down while the directory has exactly one child and that child is itself a directory
    /// (not a file) — the chain-collapsing rule. Stops as soon as a directory has more than one
    /// child, or its only child is a file (nothing to collapse into).
    private static func collapsedDirectory<Payload: Sendable & Equatable>(
        name: String, path: String, node: Trie<Payload>, salt: String
    ) -> FileTreeNode<Payload> {
        var name = name
        var path = path
        var node = node
        while node.children.count == 1, let (childName, child) = node.children.first, child.item == nil {
            name = joined(name, childName)
            path = joined(path, childName)
            node = child
        }
        return .directory(name: name, path: path, id: "dir:\(salt):\(path)", children: convert(node, path: path, salt: salt))
    }

    private static func joined(_ prefix: String, _ component: String) -> String {
        prefix.isEmpty ? component : "\(prefix)/\(component)"
    }

    private static func directoryName<Payload>(_ node: FileTreeNode<Payload>) -> String {
        if case .directory(let name, _, _, _) = node { return name }
        return ""
    }

    private static func fileSortKey<Payload>(_ node: FileTreeNode<Payload>) -> String {
        if case .file(_, let path, _) = node { return (path as NSString).lastPathComponent }
        return ""
    }
}
