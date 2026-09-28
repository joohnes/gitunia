import SwiftUI

/// Lets `GituniaApp`'s `.commands` (which lives in the Scene, not the view tree) reach the
/// currently-focused window's "open the command palette" action without a NotificationCenter
/// post or a global singleton: `ContentView` publishes a binding via `.focusedValue`, and the
/// ⌘K menu command reads it back with `@FocusedValue`.
private struct PaletteOpenKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// The file ⌘⇧O should open: a repo-relative `path` plus the repository's `url`, so the same
/// channel works whether the file came from `ChangesView`'s selection (Changes mode) or
/// `CommitDiffView`'s file list (History mode) — unlike a `FileChange`, which only Changes mode
/// has one of.
struct EditorTarget: Equatable {
    let repoURL: URL
    let path: String
}

/// Same channel as `paletteOpen`, carrying the file whose diff/file-list selection is on screen so
/// `GituniaApp`'s ⌘⇧O command knows what to open and can disable itself when there's nothing to
/// open. Published read-only (not a `Binding`) since the command never needs to change it.
private struct EditorTargetKey: FocusedValueKey {
    typealias Value = EditorTarget?
}

extension FocusedValues {
    var paletteOpen: Binding<Bool>? {
        get { self[PaletteOpenKey.self] }
        set { self[PaletteOpenKey.self] = newValue }
    }

    var editorTarget: EditorTarget? {
        get { self[EditorTargetKey.self] ?? nil }
        set { self[EditorTargetKey.self] = newValue }
    }
}

/// Whether the ⌘K palette is showing, read by the views underneath it (`ChangesView`,
/// `DiffBodyView`) so their key handlers refuse to act while it's up. Top-down `.environment`,
/// unlike `paletteOpen` (`.focusedValue`, bottom-up to the menu command).
private struct PaletteIsOpenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPaletteOpen: Bool {
        get { self[PaletteIsOpenKey.self] }
        set { self[PaletteIsOpenKey.self] = newValue }
    }
}

/// Holds the window a `ContentView` lives in. A reference type on purpose: the ⌘K monitor's
/// escaping closure and the probe below share this one object, so the monitor always sees the
/// current window — reading a `@State` value from inside that closure returned a stale `nil`.
final class HostWindowBox {
    weak var window: NSWindow?
}

/// Records the hosting window into `box` the moment the view is attached (`viewDidMoveToWindow`).
struct HostWindowReader: NSViewRepresentable {
    let box: HostWindowBox

    final class Probe: NSView {
        var box: HostWindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.box = box
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.box = box }
}
