import XCTest
import SwiftUI
import AppKit
@testable import GituniaCore

final class AccentChoiceTests: XCTestCase {
    func testRoundTripAllCases() throws {
        for choice in [AccentChoice.brand, .system, .custom(red: 0.1, green: 0.5, blue: 0.9)] {
            let data = try JSONEncoder().encode(choice)
            XCTAssertEqual(try JSONDecoder().decode(AccentChoice.self, from: data), choice)
        }
        XCTAssertEqual(String(data: try JSONEncoder().encode(AccentChoice.system), encoding: .utf8), "\"system\"")
    }

    func testSettingsRoundTripAndLegacyDefault() throws {
        var s = AppSettings()
        s.accent = .custom(red: 0.2, green: 0.3, blue: 0.4)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)), s)
        let legacy = Data(#"{"aiProvider":"ollama","appearance":"dark"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: legacy).accent, .brand)
    }

    @MainActor
    func testBrandHonorsOverride() throws {
        defer { Theme.accentOverride = nil }
        _ = Theme.accent(.custom(red: 0.2, green: 0.4, blue: 0.6))
        // Resolve under light appearance explicitly: a render test earlier in the same process can
        // leave the app in dark mode, where the custom accent is its lifted dark variant.
        var c: NSColor!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            c = NSColor(Theme.brand).usingColorSpace(.sRGB)
        }
        XCTAssertEqual(c.redComponent, 0.2, accuracy: 0.01)
        XCTAssertEqual(c.greenComponent, 0.4, accuracy: 0.01)
        XCTAssertEqual(c.blueComponent, 0.6, accuracy: 0.01)

        _ = Theme.accent(.brand)
        XCTAssertNil(Theme.accentOverride)
        _ = Theme.accent(.system)
        XCTAssertEqual(Theme.accentOverride, .controlAccentColor)
    }
}
