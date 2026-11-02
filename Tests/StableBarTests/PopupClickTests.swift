import AppKit
import SwiftUI
import Testing
@testable import StableBar

@Test(arguments: [false, true]) @MainActor func horizontalPopupListsScrollToTheirLastEntry(fillsHeight: Bool) async throws {
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(#"""
    {"type":"list","source":"apps","orientation":"horizontal","style":{"spacing":11},
     "row":{"type":"field","field":"app","wrap":true,"maxHeight":20,"style":{"width":100}}}
    """#.utf8))
    let context = BlockContext(lists: ["apps": [["app": "Mail\nInbox"], ["app": "Messages\nUnread"], ["app": "Reminders\nToday"]]],
                               open: { _ in }, runAction: { _, _ in })
    let host = NSHostingView(rootView: PopupBlockView(block: block, inheritedStyle: WidgetStyle(), fields: [:], context: context)
        .environment(\.popupFillsHeight, fillsHeight)
        .frame(width: 180, height: fillsHeight ? 80 : nil))
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -9000, y: -6000, width: 180, height: 80), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    // Scroll bars that are always shown, as on a Mac without a trackpad and on CI, take their height from a list that fills
    // the popup's height. Overlay scroll bars take nothing.
    func height(_ scroll: NSScrollView) -> CGFloat {
        guard fillsHeight else { return 20 }
        return 80 - (scroll.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0)
    }
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if let scroll = scrolls(host).first, let document = scroll.documentView,
           abs(document.bounds.width - 322) < 0.5, abs(document.bounds.height - height(scroll)) < 0.5,
           abs(scroll.contentSize.width - 180) < 0.5 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let scroll = try #require(scrolls(host).first)
    let document = try #require(scroll.documentView)
    let height = height(scroll)
    #expect(abs(document.bounds.width - 322) < 0.5)
    #expect(abs(document.bounds.height - height) < 0.5)
    #expect(abs(scroll.contentSize.width - 180) < 0.5)
    let lastEntry = CGRect(x: 222, y: 0, width: 100, height: height)
    #expect(!document.visibleRect.contains(lastEntry))
    document.scrollToVisible(lastEntry)
    #expect(document.visibleRect.contains(lastEntry))
}

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
