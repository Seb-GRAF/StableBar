import AppKit
import SwiftUI
import Testing
@testable import StableBar

@Test @MainActor func menuBarItemsOnTheBarKeepTheWidgetsOwnRightClickCommands() async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"left","shown":[{"app":"org.stablebar.not-running"},"symbol"]}]}
    """#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // SwiftUI hit-tests only a window that's on screen; a transparent one stays out of sight.
    window.alphaValue = 0
    defer { window.close() }
    let host = NSHostingView(rootView: BarView(store: store, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)))
    host.sizingOptions = []
    window.contentView = host
    window.orderFrontRegardless()

    /// The titles of the menu a right-click at `point` opens, read without opening it.
    func rightClickMenu(at point: CGPoint) -> [String] {
        // The factory leaves the button number at 0, which SwiftUI takes for a left click.
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: host.convert(point, to: nil), modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1)?.cgEvent?.copy() else { return [] }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 1)
        return NSEvent(cgEvent: event).flatMap(host.menu(for:))?.items.map(\.title) ?? []
    }
    var symbolMenu: [String]?
    try await awaitCondition {
        host.layoutSubtreeIfNeeded()
        symbolMenu = stride(from: 2.0, to: 100, by: 4).lazy.flatMap { y in
            stride(from: 2.0, to: 200, by: 4).lazy.map { x in rightClickMenu(at: CGPoint(x: x, y: y)) }
        }.first { $0.contains("Hide") }
        return symbolMenu != nil
    }
    let titles = try #require(symbolMenu)
    #expect(titles.prefix(3) == ["Move Left", "Move Right", ""], "The symbol's own commands come first: \(titles)")
    #expect(titles.contains("Edit Widget…"), "Right-clicking an item or the symbol still offers to edit the widget: \(titles)")
    #expect(titles.contains("Quit StableBar"), "The bar's own commands follow: \(titles)")
}
