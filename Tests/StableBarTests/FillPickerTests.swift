import Foundation
import SwiftUI
import Testing
@testable import StableBar

@MainActor
struct FillPickerTests {
    @Test(arguments: [
        (0.0, 0), (90, 90), (360, 0), (450, 90), (-90, 270), (-450, 270),
        (89.9, 89), (-0.5, 0), (1e20, 280), (-1e20, 80), (1e300, 0), (-1e300, 0),
        (Double.greatestFiniteMagnitude, 128), (-Double.greatestFiniteMagnitude, 232),
        (Double.nan, 0), (Double.infinity, 0), (-Double.infinity, 0)
    ])
    func gradientAnglesNormalizeBeforeIntegerConversion(angle: Double, expected: Int) {
        #expect(fillGradientAngle(angle) == expected)
    }

    @Test(arguments: ["1e300", "-1e300"])
    func fillButtonsCanReadLargeGradientAngles(angle: String) throws {
        let value = try JSONDecoder().decode(ConfigurationValue.self, from: Data(##"""
        {"gradient":{"colors":["#000000","#ffffff"],"angle":\##(angle)}}
        """##.utf8))
        _ = FillButton(title: "Background", value: value, tokens: [], set: { _ in }).body
    }
}
