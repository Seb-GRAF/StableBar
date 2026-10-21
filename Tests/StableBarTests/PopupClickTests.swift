import AppKit
import SwiftUI
import Testing
@testable import StableBar

/// A popup block's click reaches its action anywhere inside the box its style gives it, not only on
/// its glyph: a 42-point play button around a 17-point symbol.
@Test(arguments: [#""onClick":"play""#, #""open":"com.apple.Music""#]) @MainActor
func popupBlockActionsFireAcrossTheirStyledBox(action: String) throws {
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(#"""
        {"type":"symbol","name":"play.fill","alignment":"center",\#(action),
         "style":{"width":42,"height":42,"iconSize":17,"cornerRadius":21,"background":"#000000"}}
        """#.utf8))
    var clicks = 0
    let context = BlockContext(open: { _ in clicks += 1 }, runAction: { _, _ in clicks += 1 })
    let view = PopupBlockView(block: block, inheritedStyle: WidgetStyle(), fields: [:], context: context)
    _ = NSApplication.shared
    // SwiftUI hit-tests only a window that's on screen; a transparent one stays out of sight.
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = NSHostingView(rootView: view.frame(width: 100, height: 100))
    window.orderFrontRegardless()
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    // The glyph's center, then points inside the box's edges, away from the glyph.
    let points = [(0, 0), (16, 0), (-16, 0), (0, 16), (0, -16), (16, 16), (-16, -16)]
    for (index, (x, y)) in points.enumerated() {
        let point = CGPoint(x: 50 + x, y: 50 + y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(clicks == index + 1, "A click \(x), \(y) points from the center")
        clicks = index + 1
    }
}
