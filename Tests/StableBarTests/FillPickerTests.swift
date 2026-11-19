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
        _ = NSHostingView(rootView: FillButton(title: "Background", value: value, tokens: [], set: { _ in })).fittingSize
    }

    @Test(arguments: [
        (##""@token.text""##, true, ##""#30d33cff""##, ##"{"light":"@token.text","dark":"#30d33cff"}"##),
        (##"{"light":"@token.text","dark":"#30d33c"}"##, true, ##""@token.text""##, ##""@token.text""##),
        (##"{"light":"@token.text","dark":"#30d33c"}"##, false, ##""@token.accent""##, ##"{"light":"@token.accent","dark":"#30d33cff"}"##),
        (##"{"light":"#30d33c","dark":"@token.text"}"##, false, ##""#112233ff""##, ##"{"light":"#112233ff","dark":"@token.text"}"##),
        (##""#112233""##, false, ##""#445566ff""##, ##"{"light":"#445566ff","dark":"#112233ff"}"##),
        (##"{"light":"#112233","dark":"#445566"}"##, false, ##""#445566ff""##, ##""#445566ff""##),
        (##"{"light":{"light":"#111111","dark":"#eeeeee"},"dark":"#30d33c"}"##, true, ##""#000000ff""##,
         ##"{"light":"#111111ff","dark":"#000000ff"}"##),
        (##"{"gradient":{"colors":["#000000","#ffffff"]}}"##, true, ##""@token.text""##, ##""@token.text""##),
        ("null", false, ##""#30d33cff""##, ##""#30d33cff""##),
        (##"{"light":"@token.text","dark":"#30d33c"}"##, false, ##"{"gradient":{"colors":["#000000","#ffffff"]}}"##,
         ##"{"gradient":{"colors":["#000000","#ffffff"]}}"##),
        (##"{"light":"@token.text","dark":"#30d33c"}"##, true, "null", "null")
    ])
    func settingOneSideOfAColorKeepsTheOtherAndMergesEqualSides(value: String, dark: Bool, side: String, expected: String) throws {
        let decoded = { (json: String) in try JSONDecoder().decode(ConfigurationValue.self, from: Data(json.utf8)) }
        #expect(try settingColorSide(dark: dark, of: decoded(value), to: decoded(side)) == decoded(expected))
    }
}
