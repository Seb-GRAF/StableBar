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

/// A menu bar item of `owner`'s, with a one-row menu if `hasMenu`, as Accessibility reports it.
private final class FakeMenuBarItem: @unchecked Sendable {
    let owner: pid_t
    let hasMenu: Bool
    let frame: CGRect
    let bar = AXUIElementCreateApplication(900_001)
    let item = AXUIElementCreateApplication(900_002)
    let menu = AXUIElementCreateApplication(900_003)
    let row = AXUIElementCreateApplication(900_004)

    init(owner: pid_t, hasMenu: Bool = true) {
        self.owner = owner
        self.hasMenu = hasMenu
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
        case (kAXChildrenAttribute, 900_002): return hasMenu ? [menu] as CFArray : nil
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

/// Right-clicks the item of a bar that shows `fake` and has `appMenu`, once the bar has laid it out.
@MainActor private func rightClickItem(of fake: FakeMenuBarItem, with appMenu: AppMenu, inMenuBar: Bool = true,
                                       then check: (BarStore) async throws -> Void) async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"left","shown":[{"app":"com.apple.dock"}],"hidden":["symbol"],
                 "rightClickInMenuBar":\#(inMenuBar)}]}
    """#)
    defer { fixture.close() }
    let store = try fixture.store(appMenu: appMenu)
    defer { store.stop() }
    #expect(await store.appMenu.readMenuBarItems(requestingAccess: false))
    try #require(store.appMenu.menuBarItems.map(\.entry.hasSubmenu) == [false])
    let bar = HostedBar(store: store)
    defer { bar.window.close() }

    var found: RightClickView?
    try await awaitCondition {
        bar.host.layoutSubtreeIfNeeded()
        found = descendants(of: bar.host).lazy.compactMap { $0 as? RightClickView }.first
        return found != nil
    }
    let capture = try #require(found)
    let center = bar.host.convert(CGPoint(x: capture.bounds.midX, y: capture.bounds.midY), from: capture)
    capture.rightMouseDown(with: try #require(bar.rightMouseDown(at: center)))
    try await check(store)
}

@Test @MainActor func rightClickingAnItemWithoutAMenuOnTheBarRightClicksItInTheMenuBar() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier, hasMenu: false)
    let menuBar = FakeMenuBar(shown: true)
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: fake.read, sleep: { _ in await Task.yield() },
                          menuBar: menuBar.visibility, mouse: menuBar.mouse)
    try await rightClickItem(of: fake, with: appMenu) { store in
        try await awaitCondition { menuBar.steps.contains("click") }
        #expect(menuBar.heldPollsAtClick == [-1], "The right-click goes out only once the right button is up")
        let display = try #require(store.appMenu.menuBarItems.first?.entry.menuBarDisplay)
        #expect(menuBar.windowDisplays == [display], "The click goes to MenuBarAgent's window for the item's display")
        #expect(menuBar.clicks == [FakeMenuBar.Click(point: CGPoint(x: fake.frame.midX, y: fake.frame.midY), window: FakeMenuBar.window)],
                "The right-click goes to MenuBarAgent, for the middle of the item in the menu bar")
        #expect(menuBar.steps == ["click"], "A menu bar that shows is clicked as it is")
        #expect(!store.popup.isOpen, "The bar opens no menu of its own for the item")
    }
}

@Test @MainActor func rightClickingAnItemWithoutAMenuPressesItUnlessTurnedOn() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier, hasMenu: false)
    let menuBar = FakeMenuBar(shown: true)
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: fake.read, sleep: { _ in await Task.yield() },
                          menuBar: menuBar.visibility, mouse: menuBar.mouse)
    try await rightClickItem(of: fake, with: appMenu, inMenuBar: false) { store in
        try await awaitCondition { menuBar.showsChecks == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(menuBar.showsChecks == 1, "The item gets one press, as on a click")
        #expect(menuBar.heldPolls == 3 && menuBar.steps.isEmpty, "Off by default: nothing is read from the menu bar and no click is sent")
        #expect(!store.popup.isOpen)
    }
}

/// A hidden menu bar is revealed transparent for the right-click, so that a menu the click opens shows under the item,
/// and hides again afterwards.
@Test @MainActor func aHiddenMenuBarIsRevealedTransparentForTheRightClick() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier, hasMenu: false)
    let menuBar = FakeMenuBar(shown: false)
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: fake.read, sleep: { _ in await Task.yield() },
                          menuBar: menuBar.visibility, mouse: menuBar.mouse)
    try await rightClickItem(of: fake, with: appMenu) { _ in
        try await awaitCondition { menuBar.steps.last == "visible" }
        #expect(menuBar.steps == ["transparent", "revealed", "click", "hidden", "visible"])
    }
}

@Test @MainActor func anItemGetsAPressWhereAClickCanNotBeSentToTheMenuBar() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier, hasMenu: false)
    let menuBar = FakeMenuBar(shown: true, window: nil)
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: fake.read, sleep: { _ in await Task.yield() },
                          menuBar: menuBar.visibility, mouse: menuBar.mouse)
    try await rightClickItem(of: fake, with: appMenu) { _ in
        try await awaitCondition { menuBar.heldPolls < 0 }
        for _ in 0..<20 { await Task.yield() }
        #expect(menuBar.steps.isEmpty, "Without MenuBarAgent's window no click is sent")
    }
}

@Test func aRightClickForMenuBarAgentNamesItsWindow() throws {
    let field = try #require(PrivateAPI.eventWindowField)
    try #require(PrivateAPI.setEventWindowLocation != nil)
    let window = MenuBarWindow(agent: 77, number: 4242, frame: CGRect(x: 1000, y: 0, width: 800, height: 33))
    let events = menuBarRightClick(at: CGPoint(x: 1300, y: 14), in: window)
    #expect(events.map(\.type) == [.rightMouseDown, .rightMouseUp])
    #expect(events.map { $0.getIntegerValueField(field) } == [4242, 4242])
    #expect(events.map(\.location) == [CGPoint(x: 1300, y: 14), CGPoint(x: 1300, y: 14)])
    #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1])
}

/// The window list of a MacBook whose menu bar hides automatically, as macOS 27.2 describes it, beside an external display.
@Test func aRightClickGoesToMenuBarAgentsOwnWindowAlongTheDisplaysTop() {
    func window(_ owner: pid_t, _ layer: Int, _ number: Int, _ bounds: CGRect) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: owner), kCGWindowLayer as String: layer, kCGWindowNumber as String: number,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982), external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let agent: pid_t = 77
    let windows = [
        window(0, 24, 89554, CGRect(x: 0, y: -33, width: 1512, height: 33)),
        window(agent, 25, 91168, CGRect(x: 0, y: 0, width: 1512, height: 33)),
        window(agent, 24, 72310, CGRect(x: 1512, y: 0, width: 2560, height: 24)),
        window(agent, 24, 72399, CGRect(x: 0, y: 0, width: 1512, height: 982)),
        window(88, 24, 6543, CGRect(x: 0, y: 0, width: 1512, height: 33)),
        window(agent, 24, 72305, CGRect(x: 0, y: 0, width: 1512, height: 33)),
    ]
    #expect(menuBarAgentWindow(agent: agent, display: laptop, windows: windows)
                == MenuBarWindow(agent: agent, number: 72305, frame: CGRect(x: 0, y: 0, width: 1512, height: 33)),
            "Not the window server's menu bar, the strip over it, another display's window, a full-screen one or another app's")
    #expect(menuBarAgentWindow(agent: agent, display: external, windows: windows)?.number == 72310)
    #expect(menuBarAgentWindow(agent: 99, display: laptop, windows: windows) == nil)
}

/// A menu bar that records what's done to it, with a right button that reads as held for three polls.
private final class FakeMenuBar: @unchecked Sendable {
    struct Click: Equatable {
        let point: CGPoint
        let window: MenuBarWindow
    }

    static let window = MenuBarWindow(agent: 77, number: 4242, frame: CGRect(x: 0, y: 0, width: 1512, height: 33))

    private let lock = NSLock()
    private let window: MenuBarWindow?
    private var shown: Bool
    private var showsChecked = 0
    private var held = 3
    private var recorded: [String] = []
    private var clicked: [Click] = []
    private var looked: [CGDirectDisplayID] = []
    private var heldAtClick: [Int] = []

    init(shown: Bool, window: MenuBarWindow? = FakeMenuBar.window) {
        self.shown = shown
        self.window = window
    }

    var steps: [String] { lock.withLock { recorded } }
    var clicks: [Click] { lock.withLock { clicked } }
    var windowDisplays: [CGDirectDisplayID] { lock.withLock { looked } }
    var heldPolls: Int { lock.withLock { held } }
    /// Only a press asks whether the menu bar shows.
    var showsChecks: Int { lock.withLock { showsChecked } }
    var heldPollsAtClick: [Int] { lock.withLock { heldAtClick } }

    var visibility: MenuBarVisibility {
        MenuBarVisibility(shows: { _ in
                              self.lock.withLock {
                                  self.showsChecked += 1
                                  return self.shown
                              }
                          },
                          setHidden: { hidden in self.lock.withLock { self.recorded.append(hidden ? "transparent" : "visible") } },
                          setShown: { shown, _ in
                              self.lock.withLock {
                                  self.shown = shown
                                  self.recorded.append(shown ? "revealed" : "hidden")
                              }
                          })
    }

    var mouse: MenuBarMouse {
        MenuBarMouse(rightButtonIsDown: {
            self.lock.withLock {
                self.held -= 1
                return self.held >= 0
            }
        }, menuBarWindow: { display in
            self.lock.withLock {
                self.looked.append(display)
                return self.window
            }
        }, rightClick: { point, window in
            self.lock.withLock {
                self.recorded.append("click")
                self.clicked.append(Click(point: point, window: window))
                self.heldAtClick.append(self.held)
            }
        })
    }
}

@MainActor private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
}
