import Observation
import SwiftUI
import AppKit

extension AppearanceMode {
    /// Applied app-wide via `NSApp.appearance` rather than per-window `.preferredColorScheme`:
    /// the latter only restyles SwiftUI content, so the sidebar's vibrancy material, the toolbar
    /// and the Settings window kept whichever appearance they last had and the app ended up half
    /// light, half dark after toggling. `nil` follows the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension AccentChoice {
    /// `nil` for `.brand` (use the built-in orange). Custom colors get a dark variant lifted
    /// toward white so they don't sink into a dark surface.
    public var nsColor: NSColor? {
        switch self {
        case .brand: return nil
        case .system: return .controlAccentColor
        case let .custom(red, green, blue):
            let light = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            let dark = light.blended(withFraction: 0.2, of: .white) ?? light
            return Theme.dynamicNS(light: light, dark: dark, name: "GituniaCustomAccent")
        }
    }
}

/// Dynamic color palette: every member resolves live off the current NSAppearance rather than
/// branching at construction time, so it tracks system/app appearance changes for free.
public enum Theme {
    fileprivate static func dynamicNS(light: NSColor, dark: NSColor, name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func dynamic(light: NSColor, dark: NSColor, name: String) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, name: name))
    }

    /// Replaces `brand` when the user picked a non-default accent (`AccentChoice.nsColor`).
    /// Only written on the main actor, from `accent(_:)` during a view body. Backed by an
    /// `@Observable` box so every body that reads `Theme.brand` (dots, chips, badges) re-renders
    /// when the accent changes — a plain static would leave them on the old color until something
    /// else happened to redraw them.
    public static var accentOverride: NSColor? {
        get { ThemeState.shared.accentOverride }
        set { ThemeState.shared.accentOverride = newValue }
    }

    /// Sets `accentOverride` from `choice` and returns the resulting `brand`. Call it from a body
    /// that reads `settings.accent` (e.g. `.tint(Theme.accent(app.settings.accent))`): the read
    /// makes that body depend on the setting, and setting the override in the same pass (not in an
    /// `.onChange`, which runs after the body) means the tint is right on the very first frame.
    /// Views that read `Theme.brand` directly pick the change up on their next body evaluation.
    @MainActor
    public static func accent(_ choice: AccentChoice) -> Color {
        accentOverride = choice.nsColor
        return brand
    }

    private static func rgb(_ light: (Double, Double, Double), _ dark: (Double, Double, Double), _ name: String, alpha: Double = 1) -> Color {
        dynamic(light: NSColor(red: light.0, green: light.1, blue: light.2, alpha: alpha),
                dark: NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: alpha), name: "Gitunia" + name)
    }

    /// Gitunia brand orange. Dark variant is lifted and desaturated to avoid glowing on a dark surface.
    /// Reads `ThemeState.shared.accentColor` (an observed stored property, cached in `accentOverride`'s
    /// `didSet`) rather than converting `NSColor` -> `Color` here, so this stays allocation-free and the
    /// tracked access — the one that makes a SwiftUI body depend on this — is the stored property read.
    public static var brand: Color { ThemeState.shared.accentColor ?? brandDefault }
    private static let brandDefault = rgb((0.91, 0.39, 0.10), (1.00, 0.54, 0.24), "Brand")

    public static let diffAdded = rgb((0.75, 0.93, 0.75), (0.11, 0.26, 0.13), "DiffAdded")
    public static let diffRemoved = rgb((0.96, 0.78, 0.78), (0.32, 0.12, 0.12), "DiffRemoved")
    public static let diffContextBackground = dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.06), name: "GituniaDiffContextBackground")
    public static let gutterBackground = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.10), name: "GituniaGutterBackground")

    // `.modified` was `.orange`, which now collides with the brand accent; amber reads distinctly.
    private static let statusModified = rgb((0.80, 0.62, 0.00), (0.95, 0.80, 0.20), "StatusModified")
    private static let statusAdded = rgb((0.20, 0.60, 0.20), (0.40, 0.80, 0.40), "StatusAdded")
    private static let statusDeleted = rgb((0.80, 0.20, 0.20), (0.95, 0.45, 0.45), "StatusDeleted")
    private static let statusRenamed = rgb((0.20, 0.40, 0.85), (0.45, 0.65, 1.00), "StatusRenamed")
    private static let statusConflicted = rgb((0.60, 0.25, 0.75), (0.75, 0.55, 0.90), "StatusConflicted")

    public static func status(_ status: FileChange.Status) -> Color {
        switch status {
        case .modified: statusModified
        case .added, .untracked: statusAdded
        case .deleted: statusDeleted
        case .renamed: statusRenamed
        case .conflicted: statusConflicted
        }
    }

    private static let syntaxKeyword = rgb((0.60, 0.20, 0.75), (0.78, 0.48, 0.92), "SyntaxKeyword")
    private static let syntaxString = rgb((0.80, 0.15, 0.15), (0.95, 0.45, 0.45), "SyntaxString", alpha: 0.85)
    private static let syntaxComment = Color(nsColor: .secondaryLabelColor)
    private static let syntaxNumber = rgb((0.15, 0.35, 0.85), (0.45, 0.60, 1.00), "SyntaxNumber")

    public static func syntax(_ kind: SyntaxToken.Kind) -> Color {
        switch kind {
        case .keyword: syntaxKeyword
        case .string: syntaxString
        case .comment: syntaxComment
        case .number: syntaxNumber
        case .plain: Color.primary
        }
    }
}

/// Observation box behind `Theme.accentOverride`; see its doc comment.
@Observable
public final class ThemeState: @unchecked Sendable {
    public static let shared = ThemeState()
    public var accentOverride: NSColor? {
        didSet { accentColor = accentOverride.map { Color(nsColor: $0) } }
    }
    /// Cached conversion of `accentOverride`, recomputed only on write. `brand` reads this instead
    /// of converting on every access, keeping the hot path allocation-free.
    public private(set) var accentColor: Color?
    private init() {}
}
