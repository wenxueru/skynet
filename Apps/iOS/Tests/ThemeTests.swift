import SwiftUI
import UIKit
import XCTest
@testable import Skynet

@MainActor
final class ThemeTests: XCTestCase {
    func testLightPaletteIsPreserved() {
        assertPalette(.light, expected: [
            [0.10, 0.36, 0.78, 1], [0.13, 0.55, 0.28, 1],
            [0.72, 0.51, 0.05, 1], [0.75, 0.19, 0.17, 1],
            [0.89, 0.94, 1.0, 1], [0.95, 0.95, 0.96, 1],
            [0.965, 0.965, 0.97, 1], [0.93, 0.94, 0.95, 1],
        ])
    }

    func testDarkPaletteIsPreserved() {
        assertPalette(.dark, expected: [
            [0.40, 0.66, 1.0, 1], [0.42, 0.80, 0.48, 1],
            [0.95, 0.76, 0.31, 1], [0.96, 0.51, 0.48, 1],
            [0.12, 0.22, 0.37, 1], [0.13, 0.13, 0.15, 1],
            [0.11, 0.11, 0.13, 1], [0.08, 0.08, 0.10, 1],
        ])
    }

    private func assertPalette(_ style: UIUserInterfaceStyle, expected: [[CGFloat]]) {
        let colors = [Theme.accent, Theme.success, Theme.warning, Theme.danger,
                      Theme.userBubble, Theme.assistantBubble, Theme.toolCallBackground, Theme.codeBackground]
        XCTAssertEqual(colors.count, expected.count)
        for (color, components) in zip(colors, expected) {
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            for (actual, expected) in zip([red, green, blue, alpha], components) {
                XCTAssertEqual(actual, expected, accuracy: 0.000001)
            }
        }
    }
}
