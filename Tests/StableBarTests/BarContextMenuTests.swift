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
@MainActor private func rightClickItem(of fake: FakeMenuBarItem, with appMenu: AppMenu, then check: (BarStore) async throws -> Void) async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"left","shown":[{"app":"com.apple.dock"}],"hidden":["symbol"]}]}
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
    appMenu.coverMenuBar = { menuBar.record($0 ? "covered" : "uncovered") }
    try await rightClickItem(of: fake, with: appMenu) { store in
        try await awaitCondition { menuBar.steps.contains("click") }
        #expect(menuBar.heldPollsAtClick == [-1], "The right-click goes out only once the right button is up")
        let display = try #require(store.appMenu.menuBarItems.first?.entry.menuBarDisplay)
        #expect(menuBar.clicks == [FakeMenuBar.Click(point: CGPoint(x: fake.frame.midX, y: fake.frame.midY),
                                                     context: MenuBarContext(agent: 77, number: 4242, menuBar: CGDisplayBounds(display)))],
                "The right-click goes to MenuBarAgent, for the middle of the item in the menu bar")
        #expect(menuBar.steps == ["uncovered", "context", "click"], "A menu bar that shows gives its context as it is, over the bars")
        #expect(menuBar.probes == [FakeMenuBar.Probe(agent: 77, row: CGRect(x: CGDisplayBounds(display).minX, y: fake.frame.minY,
                                                                              width: CGDisplayBounds(display).width, height: fake.frame.height),
                                                     item: fake.frame)])
        #expect(!store.popup.isOpen, "The bar opens no menu of its own for the item")
    }
}

/// A hidden menu bar is revealed transparent. macOS gives a mouse event on it to the window beneath, so the menu bar
/// shows faintly while its context is read, which happens once.
@Test @MainActor func aHiddenMenuBarShowsFaintlyOnlyWhileItsContextIsRead() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier, hasMenu: false)
    let menuBar = FakeMenuBar(shown: false)
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: fake.read, sleep: { _ in await Task.yield() },
                          menuBar: menuBar.visibility, mouse: menuBar.mouse)
    appMenu.coverMenuBar = { menuBar.record($0 ? "covered" : "uncovered") }
    try await rightClickItem(of: fake, with: appMenu) { store in
        try await awaitCondition { menuBar.steps.last == "visible" }
        #expect(menuBar.steps == ["transparent", "revealed", "sliding", "sliding", "covered", "opacity 0.06", "context", "opacity 0.0",
                                  "uncovered", "click", "hidden", "visible"],
                "The context is read once the menu bar has slid all the way down, with the bars over it for as long as it's faint")
        menuBar.forget()
        store.appMenu.rightClick(try #require(store.appMenu.menuBarItems.first).entry)
        try await awaitCondition { menuBar.steps.last == "visible" }
        #expect(menuBar.steps == ["transparent", "revealed", "click", "hidden", "visible"], "A second right-click knows the context")
    }
}

@Test @MainActor func anItemGetsAPressWhereAClickCanNotBeSentToTheMenuBar() async throws {
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let fake = FakeMenuBarItem(owner: dock.processIdentifier, hasMenu: false)
    let menuBar = FakeMenuBar(shown: true, agent: nil)
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: fake.read, sleep: { _ in await Task.yield() },
                          menuBar: menuBar.visibility, mouse: menuBar.mouse)
    try await rightClickItem(of: fake, with: appMenu) { _ in
        try await awaitCondition { menuBar.heldPolls < 0 }
        for _ in 0..<20 { await Task.yield() }
        #expect(menuBar.steps.isEmpty, "Without MenuBarAgent nothing is read from the menu bar and no click is sent")
    }
}

/// A bar drops this event, which was meant for a menu bar that didn't take it.
@Test func theEventThatReadsAMenuBarsContextIsToldFromTheMouses() throws {
    func event(_ type: CGEventType, marked: Bool) throws -> NSEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: menuBarProbeButton)
        if marked { event.setIntegerValueField(.eventSourceUserData, value: menuBarProbeMark) }
        return try #require(NSEvent(cgEvent: event))
    }
    #expect(try event(.otherMouseUp, marked: true).isMenuBarProbe)
    #expect(try !event(.otherMouseUp, marked: false).isMenuBarProbe, "A release of the mouse's still reaches the bar")
    #expect(try !event(.otherMouseDown, marked: true).isMenuBarProbe)
}

@Test func aMenuBarsContextIsReadWhereThePointerIsIfThatIsAmongItsItems() {
    let row = CGRect(x: 0, y: 2, width: 3440, height: 24), item = CGRect(x: 100, y: 2, width: 60, height: 24)
    #expect(menuBarProbePoint(row: row, item: item, pointer: CGPoint(x: 900, y: 20)) == CGPoint(x: 900, y: 20), "The pointer stays put")
    #expect(menuBarProbePoint(row: row, item: item, pointer: CGPoint(x: 900, y: 40)) == CGPoint(x: 130, y: 14))
}

@Test func aRightClickForMenuBarAgentNamesItsContext() throws {
    let field = try #require(PrivateAPI.eventContextField)
    try #require(PrivateAPI.setEventWindowLocation != nil)
    let context = MenuBarContext(agent: 77, number: 4242, menuBar: CGRect(x: 1000, y: 0, width: 800, height: 600))
    let events = menuBarRightClick(at: CGPoint(x: 1300, y: 14), in: context)
    #expect(events.map(\.type) == [.rightMouseDown, .rightMouseUp])
    #expect(events.map { $0.getIntegerValueField(field) } == [4242, 4242])
    #expect(events.map(\.location) == [CGPoint(x: 1300, y: 14), CGPoint(x: 1300, y: 14)])
    #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1])
}

/// A menu bar that records what's done to it, with a right button that reads as held for three polls. One that starts
/// hidden is still sliding down for the first two checks after it's revealed.
private final class FakeMenuBar: @unchecked Sendable {
    struct Click: Equatable {
        let point: CGPoint
        let context: MenuBarContext
    }

    struct Probe: Equatable {
        let agent: pid_t
        let row: CGRect
        let item: CGRect
    }

    private let lock = NSLock()
    private let agent: pid_t?
    private var shown: Bool
    private var held = 3
    private var slidingPolls: Int
    private var recorded: [String] = []
    private var clicked: [Click] = []
    private var probed: [Probe] = []
    private var heldAtClick: [Int] = []

    init(shown: Bool, agent: pid_t? = 77) {
        self.shown = shown
        self.agent = agent
        slidingPolls = shown ? 0 : 2
    }

    var steps: [String] { lock.withLock { recorded } }
    var clicks: [Click] { lock.withLock { clicked } }
    var probes: [Probe] { lock.withLock { probed } }
    var heldPolls: Int { lock.withLock { held } }
    var heldPollsAtClick: [Int] { lock.withLock { heldAtClick } }

    func forget() {
        lock.withLock { recorded = [] }
    }

    func record(_ step: String) {
        lock.withLock { recorded.append(step) }
    }

    var visibility: MenuBarVisibility {
        MenuBarVisibility(shows: { _ in self.lock.withLock { self.shown } },
                          isInPlace: { _ in
                              self.lock.withLock {
                                  self.slidingPolls -= 1
                                  if self.slidingPolls >= 0 { self.recorded.append("sliding") }
                                  return self.shown && self.slidingPolls < 0
                              }
                          },
                          setHidden: { hidden in self.lock.withLock { self.recorded.append(hidden ? "transparent" : "visible") } },
                          setShown: { shown, _ in
                              self.lock.withLock {
                                  self.shown = shown
                                  self.recorded.append(shown ? "revealed" : "hidden")
                              }
                          },
                          setOpacity: { opacity in self.lock.withLock { self.recorded.append("opacity \(opacity)") } })
    }

    var mouse: MenuBarMouse {
        MenuBarMouse(rightButtonIsDown: {
            self.lock.withLock {
                self.held -= 1
                return self.held >= 0
            }
        }, agent: { self.agent }, contextNumber: { agent, row, item, _ in
            self.lock.withLock {
                self.recorded.append("context")
                self.probed.append(Probe(agent: agent, row: row, item: item))
            }
            return 4242
        }, rightClick: { point, context in
            self.lock.withLock {
                self.recorded.append("click")
                self.clicked.append(Click(point: point, context: context))
                self.heldAtClick.append(self.held)
            }
        })
    }
}

@MainActor private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
}
