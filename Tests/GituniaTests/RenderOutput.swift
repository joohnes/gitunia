import AppKit
import SwiftUI
import XCTest

/// Where the opt-in render harnesses (`RUN_PALETTE_RENDER_TESTS=1`) write their PNGs.
/// Override with `RENDER_OUTPUT_DIR`; defaults to a folder in the system temp directory.
enum RenderOutput {
    static let dir = ProcessInfo.processInfo.environment["RENDER_OUTPUT_DIR"]
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("gitunia-renders")
}

/// Base class of the offscreen render harnesses: skipped unless `RUN_PALETTE_RENDER_TESTS=1`.
@MainActor
class RenderTestCase: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_PALETTE_RENDER_TESTS"] == "1",
            "Offscreen render harness — run with RUN_PALETTE_RENDER_TESTS=1 to exercise it."
        )
    }
}

/// Sleeps 100 ms and re-lays-out, `ticks` times. A real `Task.sleep` yields the main actor, so
/// async `.task` work (git calls) gets a turn before the capture.
@MainActor
func pumpLayout(_ view: NSView, ticks: Int = 20) async {
    for _ in 0..<ticks {
        try? await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
    }
}

/// Synchronous pump for views that need a few run-loop turns (focus, onAppear) but no async work.
@MainActor
func pumpRunLoop(_ view: NSView, ticks: Int = 5) {
    for _ in 0..<ticks {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }
}

/// Snapshots `view` into `RenderOutput.dir/<name>.png`; returns the path.
@MainActor
func writePNG(_ view: NSView, name: String) throws -> String {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw XCTSkip("Could not create bitmap rep for offscreen render — cannot verify visually.")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw XCTSkip("Could not encode PNG — cannot verify visually.")
    }
    try FileManager.default.createDirectory(atPath: RenderOutput.dir, withIntermediateDirectories: true)
    let path = "\(RenderOutput.dir)/\(name).png"
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

/// Hosts `view`, framed to `size`, as the content of an offscreen borderless key window.
/// `appearance` pins host and window; nil inherits the system's.
@MainActor
func hostOffscreen(_ view: some View, size: CGSize, appearance: NSAppearance.Name? = nil,
                   activate: Bool = true) -> (NSHostingView<AnyView>, NSWindow) {
    let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    if let appearance {
        hosting.appearance = NSAppearance(named: appearance)
        window.appearance = hosting.appearance
    }
    NSApp.setActivationPolicy(.regular)
    if activate { NSApp.activate(ignoringOtherApps: true) }
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    return (hosting, window)
}

/// `view` hosted offscreen as given, pumped `ticks` times, saved as `<name>.png`.
@MainActor
func renderHostedPNG(_ view: some View, name: String, size: CGSize, appearance: NSAppearance.Name? = nil,
                     activate: Bool = true, ticks: Int = 20) async throws -> String {
    let (hosting, window) = hostOffscreen(view, size: size, appearance: appearance, activate: activate)
    defer { window.orderOut(nil) }
    await pumpLayout(hosting, ticks: ticks)
    return try writePNG(hosting, name: name)
}

/// The usual sheet render: `view` top-aligned on the window background, in `colorScheme`. `ticks`
/// (default 20, i.e. ~2s) can be raised past a known fixed dwell timer in the view under test (e.g.
/// `ActivityWindow`'s 2s "mark seen" delay) so the capture always lands on one deterministic side of
/// it instead of racing `pumpLayout`'s own ~2s of sleeping (D18).
@MainActor
func renderPNG(_ view: some View, name: String, size: CGSize, colorScheme: ColorScheme = .light, ticks: Int = 20) async throws -> String {
    let root = view.frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(colorScheme)
    return try await renderHostedPNG(root, name: name, size: size, appearance: colorScheme == .dark ? .darkAqua : .aqua, ticks: ticks)
}

/// Windowless render, for views that need neither focus nor async work.
@MainActor
func renderPlainPNG(_ view: some View, name: String, size: CGSize) throws -> String {
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    pumpRunLoop(hosting)
    return try writePNG(hosting, name: name)
}

/// Renders `view` in a titled window with an empty unified toolbar and captures the whole theme
/// frame, so the title/toolbar area is in the shot.
@MainActor
func renderToolbarPNG(_ view: some View, name: String, size: CGSize, toolbar identifier: String,
                      appearance: NSAppearance.Name, ticks: Int = 20) async throws -> String {
    let hosting = NSHostingView(rootView: AnyView(view))
    let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: identifier)
    window.appearance = NSAppearance(named: appearance)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    window.layoutIfNeeded()
    await pumpLayout(hosting, ticks: ticks)
    guard let themeFrame = window.contentView?.superview else {
        throw XCTSkip("No theme frame — cannot verify toolbar visually.")
    }
    return try writePNG(themeFrame, name: name)
}

/// Posts a synthetic key-down to `window`, as a real keystroke would arrive.
@MainActor
func sendKey(_ keyCode: UInt16, character: String, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
    )!
    window.sendEvent(event)
}
