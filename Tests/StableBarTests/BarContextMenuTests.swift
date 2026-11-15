import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import StableBar

/// A bar in a transparent window: SwiftUI hit-tests only a window that's on screen.
@MainActor private struct HostedBar {
    let window: NSWindow
    let host: NSHostingView<BarView>

    init(store: BarStore) {
        // At the top of the screen, as a bar is, so a popup has room below it.
        let screen = NSScreen.screens.first?.frame ?? .zero
        window = NSWindow(contentRect: CGRect(x: screen.minX, y: screen.maxY - 100, width: 600, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        host = NSHostingView(rootView: BarView(store: store, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)))
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
    }

    func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    func rightMouseDown(at point: CGPoint) -> NSEvent? {
        // The factory leaves the button number at 0, which SwiftUI takes for a left click.
        guard let event = mouseEvent(.rightMouseDown, at: point)?.cgEvent?.copy() else { return nil }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 1)
        return NSEvent(cgEvent: event)
    }

    /// The titles of the menu a right-click at `point` opens, read without opening it.
    func menu(at point: CGPoint) -> [String] {
        rightMouseDown(at: point).flatMap(host.menu(for:))?.items.map(\.title) ?? []
    }

    /// The first point, row by row from the top left, where a right-click opens a menu that `matches`.
    func firstPoint(where matches: ([String]) -> Bool) -> CGPoint? {
        host.layoutSubtreeIfNeeded()
        return stride(from: 2.0, to: 100, by: 4).lazy.flatMap { y in
            stride(from: 2.0, to: 200, by: 4).lazy.map { x in CGPoint(x: x, y: y) }
        }.first { matches(menu(at: $0)) }
    }
}

@Test @MainActor func theGridSymbolOnTheBarKeepsTheWidgetsOwnRightClickCommands() async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"left","shown":[{"app":"org.stablebar.not-running"},"symbol"]}]}
    """#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let bar = HostedBar(store: store)
    defer { bar.window.close() }

    var symbol: CGPoint?
    try await awaitCondition {
        symbol = bar.firstPoint { $0.contains("Hide") }
        return symbol != nil
    }
    let titles = bar.menu(at: try #require(symbol))
    #expect(titles.prefix(3) == ["Move Left", "Move Right", ""], "The symbol's own commands come first: \(titles)")
    #expect(titles.contains("Edit Widget…"), "Right-clicking the symbol still offers to edit the widget: \(titles)")
    #expect(titles.contains("Quit StableBar"), "The bar's own commands follow: \(titles)")
}

/// A menu bar item of `owner`'s with a one-row menu, as Accessibility reports it.
private final class FakeMenuBarItem: @unchecked Sendable {
    let owner: pid_t
    let frame: CGRect
    let bar = AXUIElementCreateApplication(900_001)
    let item = AXUIElementCreateApplication(900_002)
    let menu = AXUIElementCreateApplication(900_003)
    let row = AXUIElementCreateApplication(900_004)

    init(owner: pid_t) {
        self.owner = owner
        let display = CGDisplayBounds(CGMainDisplayID())
        frame = CGRect(x: display.minX + 100, y: display.minY, width: 24, height: 24)
    }

    func read(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var origin = frame.origin, size = frame.size
        switch (name, pid) {
        case (kAXExtrasMenuBarAttribute, owner): return bar
        case (kAXChildrenAttribute, 900_001): return [item] as CFArray
        case (kAXChildrenAttribute, 900_002): return [menu] as CFArray
        case (kAXChildrenAttribute, 900_003): return [row] as CFArray
        case (kAXRoleAttribute, 900_002): return kAXMenuBarItemRole as CFString
        case (kAXRoleAttribute, 900_003): return kAXMenuRole as CFString
        case (kAXTitleAttribute, 900_004): return "Row" as CFString
        case (kAXDescriptionAttribute, 900_002): return "Fake item" as CFString
        case (kAXPositionAttribute, 900_002): return AXValueCreate(.cgPoint, &origin)
        case (kAXSizeAttribute, 900_002): return AXValueCreate(.cgSize, &size)
        default: return nil
        }
    }
}

@Test @MainActor func rightClickingAnAppsItemOnTheBarOpensItLikeAClick() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier)
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"left","shown":[{"app":"com.apple.dock"}],"hidden":["symbol"]}]}
    """#)
    defer { fixture.close() }
    let store = try fixture.store(appMenu: AppMenu(checkAccess: { true }, readAttribute: fake.read))
    defer { store.stop() }
    #expect(await store.appMenu.readMenuBarItems(requestingAccess: false))
    try #require(store.appMenu.menuBarItems.map(\.entry.title) == ["Fake item"])
    let bar = HostedBar(store: store)
    defer { bar.window.close() }

    // Nothing here opens a menu: an open menu tracks the mouse, and a stray click in it could choose Quit StableBar.
    var found: RightClickView?
    try await awaitCondition {
        bar.host.layoutSubtreeIfNeeded()
        found = descendants(of: bar.host).lazy.compactMap { $0 as? RightClickView }.first
        return found != nil
    }
    let capture = try #require(found)
    let center = bar.host.convert(CGPoint(x: capture.bounds.midX, y: capture.bounds.midY), from: capture)
    #expect(!bar.menu(at: center).contains("Hide"), "The item no longer has a menu of StableBar's commands")

    // A clicked popup becomes the key window. Tests running alongside send actions to theirs, so it gets key status back
    // before this test next waits.
    let keyWindow = NSApplication.shared.keyWindow
    func closePopup() {
        store.popup.close()
        keyWindow?.makeKey()
    }
    defer { closePopup() }
    capture.rightMouseDown(with: try #require(bar.rightMouseDown(at: center)))
    #expect(store.popup.isOpen, "A right-click opens the item's menu, as a click does")

    closePopup()
    try #require(!store.popup.isOpen)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        bar.window.sendEvent(try #require(bar.mouseEvent(type, at: center)))
    }
    #expect(store.popup.isOpen, "A click still reaches the item beneath the view that takes right-clicks")
}

@MainActor private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
}
