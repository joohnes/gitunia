import XCTest
import SwiftUI
import AppKit
@testable import GituniaCore

final class ThemeTests: XCTestCase {
    private func resolve(_ color: Color, in appearance: NSAppearance) -> NSColor {
        let ns = NSColor(color)
        var resolved: NSColor!
        appearance.performAsCurrentDrawingAppearance {
            resolved = ns.usingColorSpace(.deviceRGB) ?? ns
        }
        return resolved
    }

    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!

    func testStaticMembersResolveInBothAppearances() {
        for color in [Theme.brand, Theme.diffAdded, Theme.diffRemoved, Theme.diffContextBackground, Theme.gutterBackground] {
            XCTAssertNotNil(resolve(color, in: aqua))
            XCTAssertNotNil(resolve(color, in: darkAqua))
        }
    }

    func testBrandDiffersBetweenAppearances() {
        let light = resolve(Theme.brand, in: aqua)
        let dark = resolve(Theme.brand, in: darkAqua)
        XCTAssertNotEqual(light, dark)
    }

    func testStatusResolvesForEveryCase() {
        let statuses: [FileChange.Status] = [.modified, .added, .deleted, .renamed, .untracked, .conflicted]
        for status in statuses {
            let color = Theme.status(status)
            XCTAssertNotNil(resolve(color, in: aqua))
            XCTAssertNotNil(resolve(color, in: darkAqua))
        }
    }

    func testSyntaxResolvesForEveryTokenKind() {
        let kinds: [SyntaxToken.Kind] = [.keyword, .string, .comment, .number, .plain]
        for kind in kinds {
            let color = Theme.syntax(kind)
            XCTAssertNotNil(resolve(color, in: aqua))
            XCTAssertNotNil(resolve(color, in: darkAqua))
        }
    }
}
