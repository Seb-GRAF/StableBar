import AppKit
import Testing
@testable import StableBar

/// An image of `width` by `height` pixels, each drawn by `color` as premultiplied red, green, blue and alpha.
private func image(width: Int, height: Int, color: (_ x: Int, _ y: Int) -> [UInt8]) -> CGImage {
    var bytes: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width { bytes += color(x, y) }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// The red, green, blue and alpha of each pixel of `image`'s top row.
private func topRow(_ image: NSImage) -> [[UInt8]] {
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
    let context = CGContext(data: &bytes, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: source.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    return (0..<source.width).map { Array(bytes[$0 * 4..<$0 * 4 + 4]) }
}

@Test func menuBarItemCopyOfAWhiteItemTakesTheBarsColorAndKeepsItsDimParts() throws {
    // Two empty columns, a white one, a gray one, then two empty ones.
    let copy = try #require(MenuBarItemImage(copying: image(width: 6, height: 4) { x, _ in
        x == 2 ? [255, 255, 255, 255] : x == 3 ? [128, 128, 128, 255] : [0, 0, 0, 0]
    }, scale: 2))
    #expect(copy.isTemplate)
    #expect(copy.image.size == NSSize(width: 1, height: 2))
    #expect(topRow(copy.image) == [[0, 0, 0, 255], [0, 0, 0, 128]])
}

@Test func menuBarItemCopyOfABlackItemKeepsItsShape() throws {
    let copy = try #require(MenuBarItemImage(copying: image(width: 3, height: 2) { x, _ in
        x == 1 ? [0, 0, 0, 255] : [0, 0, 0, 0]
    }, scale: 1))
    #expect(copy.isTemplate)
    #expect(topRow(copy.image) == [[0, 0, 0, 255]])
}

@Test func menuBarItemCopyOfAColoredItemKeepsItsColors() throws {
    let copy = try #require(MenuBarItemImage(copying: image(width: 2, height: 2) { x, _ in
        x == 0 ? [255, 0, 0, 255] : [255, 255, 255, 255]
    }, scale: 1))
    #expect(!copy.isTemplate)
    #expect(topRow(copy.image) == [[255, 0, 0, 255], [255, 255, 255, 255]])
}

@Test func menuBarItemCopyOfAnItemMacOSIsNotDrawingIsNil() {
    #expect(MenuBarItemImage(copying: image(width: 4, height: 4) { _, _ in [0, 0, 0, 0] }, scale: 2) == nil)
}

@Test func menuBarItemCopiesAreEqualWhenTheirPixelsAre() throws {
    func copy(_ alpha: UInt8) throws -> MenuBarItemImage {
        try #require(MenuBarItemImage(copying: image(width: 2, height: 2) { _, _ in [alpha, alpha, alpha, alpha] }, scale: 1))
    }
    #expect(try copy(255) == copy(255))
    #expect(try copy(255) != copy(200))
}

@Test func menuBarItemsLeftOfTheirBarsOverflowButtonAreCollapsed() {
    // The frames MenuBarAgent reports on a display with a notch: folded items stack under the button.
    let frames = [
        "codexbar": CGRect(x: 849, y: 4, width: 41, height: 24), "slack": CGRect(x: 855, y: 4, width: 35, height: 24),
        "1password": CGRect(x: 895, y: 4, width: 41, height: 24), "meetingbar": CGRect(x: 1184, y: 4, width: 34, height: 24)
    ]
    // The bar starts at the display's left edge and its button ends at 889.5.
    let folded = CGRect(x: 0, y: 0, width: 889.5, height: 33)
    #expect(collapsedMenuBarItems(frames, in: [folded]) == ["codexbar", "slack"])
    #expect(collapsedMenuBarItems(frames, in: []).isEmpty)
    // A display above this one, or beside it at the same height, folds none of this one's items.
    #expect(collapsedMenuBarItems(frames, in: [folded.offsetBy(dx: 0, dy: -1440), folded.offsetBy(dx: 1512, dy: 0)]).isEmpty)
}

@Test func liveMenuBarItemsDecodeAndNeedScreenRecording() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"right",
                 "shown":[{"app":"leits.MeetingBar","display":"live"},{"app":"Granola","display":"icon"},{"app":"Slack"}]},
                {"id":"off","type":"menuBarItems","position":"right","enabled":false,"shown":[{"app":"Docker","display":"live"}]}]}
    """#.utf8))
    var meetingBar = MenuBarItemReference(app: "leits.MeetingBar", item: nil)
    meetingBar.display = .live
    #expect(configuration.liveMenuBarItems == [meetingBar])
    #expect(meetingBar.configurationValue == .object(["app": .string("leits.MeetingBar"), "display": .string("live")]))
    #expect(MenuBarItemReference(app: "Slack", item: nil).configurationValue == .object(["app": .string("Slack")]))
    #expect(configuration.widgets[0].content.permissions == [.accessibility, .screenRecording])
    #expect(DataSourceRegistry.builtIn.permissions(for: configuration) == [.accessibility, .screenRecording])
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"widgets":[{"id":"items","type":"menuBarItems","position":"right","shown":[{"app":"Slack","display":"mirror"}]}]}
        """#.utf8))
    }
}

@Test func liveMenuBarItemsOnOneScreenNeedScreenRecording() throws {
    func decode(_ json: String) throws -> Configuration { try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)) }
    var configuration = try decode(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    #expect(!DataSourceRegistry.builtIn.permissions(for: configuration).contains(.screenRecording))
    configuration.screenLooks[ScreenKind.laptop.rawValue] = try decode(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"right","shown":[{"app":"leits.MeetingBar","display":"live"}]}]}
    """#)
    #expect(DataSourceRegistry.builtIn.permissions(for: configuration) == [.accessibility, .screenRecording])
}
