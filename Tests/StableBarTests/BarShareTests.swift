import AppKit
import Foundation
import SwiftUI
import Testing
@testable import StableBar

@Test func badgeSitsOnTheWallpaperBeyondTheBar() {
    let size = CGSize(width: 1512, height: 850)
    let badge = CGSize(width: 160, height: 68)
    let top = BarShare.badgeFrame(badge, in: size, bottom: false)
    #expect(top == CGRect(x: 1512 - 160 - BarShareBadge.inset, y: 850 - 68 - BarShareBadge.inset, width: 160, height: 68))
    let bottom = BarShare.badgeFrame(badge, in: size, bottom: true)
    #expect(bottom == CGRect(x: 1512 - 160 - BarShareBadge.inset, y: BarShareBadge.inset, width: 160, height: 68))
}

@Test func compositeDrawsTheBadgeOnlyInItsFrame() throws {
    let image = try #require(solid(width: 200, height: 100, red: 0))
    let badge = try #require(solid(width: 20, height: 10, red: 255))
    // At two pixels a point, the frame at (80, 30) from the top left covers pixels 160...179 across and 60...69 down.
    let composite = try #require(BarShare.composite(image, badge: badge, at: CGRect(x: 80, y: 30, width: 10, height: 5), scale: 2))
    #expect(composite.width == 200 && composite.height == 100)
    let pixels = NSBitmapImageRep(cgImage: composite)
    #expect(red(pixels, x: 170, y: 65) == 255)
    // Where it would be counted from the bottom left.
    #expect(red(pixels, x: 170, y: 35) == 0)
    #expect(red(pixels, x: 20, y: 65) == 0)
}

@MainActor @Test func badgeChoiceIsRememberedForTheNextShare() throws {
    let suite = "StableBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    func share() -> BarShare {
        BarShare(store: store, display: display, screen: CGSize(width: 1512, height: 982), menuBar: 24, wallpaper: nil, defaults: defaults)
    }
    #expect(share().badge)
    share().badge = false
    #expect(!share().badge)
    #expect(BarShare(store: store, display: display, screen: CGSize(width: 1512, height: 982), menuBar: 24, wallpaper: nil).badge)
}

@MainActor @Test func aClickOnTheBackgroundMovesTheWindowAndOneOnAControlDoesnt() throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    let share = BarShare(store: store, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil),
                         screen: CGSize(width: 1512, height: 982), menuBar: 24, wallpaper: nil)
    // SwiftUI hit-tests only a window that's on screen.
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.borderless],
                         backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    defer { window.close() }
    let host = NSHostingView(rootView: BarShareView(share: share))
    host.sizingOptions = []
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    /// Whether a click at `point`, from the top left, reaches the view that moves the window.
    func movesWindow(at point: CGPoint) -> Bool {
        let local = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        return host.hitTest(host.convert(local, to: host.superview)) is WindowDragArea.DragView
    }
    // Between the screen menu and the close button, beside the image and beside the toolbar.
    for point in [CGPoint(x: 340, y: 28), CGPoint(x: 20, y: 230), CGPoint(x: 10, y: 450)] {
        #expect(movesWindow(at: point), "\(point)")
    }
    // The screen menu, the close button and the toolbar's middle.
    for point in [CGPoint(x: 40, y: 28), CGPoint(x: 652, y: 28), CGPoint(x: 340, y: 424)] {
        #expect(!movesWindow(at: point), "\(point)")
    }
}

@Test func sceneDrawsShareMyBarInAShape() throws {
    let decoded = try JSONDecoder().decode(SceneFile.self, from: Data(#"{"configuration": {}, "draw": "share", "sharePreset": "portrait"}"#.utf8))
    #expect(decoded.sharePreset == .portrait)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SceneFile.self, from: Data(#"{"configuration": {}, "draw": "bar", "sharePreset": "square"}"#.utf8))
    }
}

private func solid(width: Int, height: Int, red: UInt8) -> CGImage? {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(red: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1)
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
}

/// The red of the pixel `x` from the left and `y` from the top.
private func red(_ image: NSBitmapImageRep, x: Int, y: Int) -> Int {
    Int(((image.colorAt(x: x, y: y)?.redComponent ?? -1) * 255).rounded())
}
