import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import StableBar

private final class MenuApplication: NSRunningApplication, @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { bundleID ?? "test.menu.\(pid)" }

    init(pid: pid_t, bundleID: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        super.init()
    }
}

private final class MenuReadFixture: @unchecked Sendable {
    var trusted = true
    var failedAttribute: String?
    var empty = false
    var title = "First"
    private let lock = NSLock()
    private var menuBarReads: [pid_t] = []
    private var retries = 0
    var reads: [pid_t] { lock.withLock { menuBarReads } }
    let menuBar = AXUIElementCreateApplication(10)
    let apple = AXUIElementCreateApplication(11)
    let app = AXUIElementCreateApplication(12)
    let file = AXUIElementCreateApplication(13)

    func read(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        if name == kAXMenuBarAttribute {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            lock.withLock { menuBarReads.append(pid) }
        }
        if name == failedAttribute, name != kAXTitleAttribute || element == apple { return nil }
        switch name {
        case kAXMenuBarAttribute: return menuBar
        case kAXChildrenAttribute: return (empty ? [] : [apple, app, file]) as CFArray
        case kAXTitleAttribute:
            return (element == apple ? "Apple" : element == app ? title : "File") as CFString
        default: return nil
        }
    }

    func sleep(_ duration: Duration) async throws {
        guard duration != .zero else { return }
        while true {
            try Task.checkCancellation()
            if takeRetry() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func allowRetry() {
        lock.withLock { retries += 1 }
    }

    private func takeRetry() -> Bool {
        lock.withLock {
            guard retries > 0 else { return false }
            retries -= 1
            return true
        }
    }

    @MainActor func waitForReads(_ count: Int) async throws {
        while reads.count < count { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(arguments: [kAXMenuBarAttribute, kAXChildrenAttribute, kAXTitleAttribute])
@MainActor func menuReadFailureKeepsCompleteMenusAndRetries(
    attribute: String
) async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read, sleep: source.sleep)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    let apple = try #require(menu.appleMenu)
    let items = menu.items
    source.failedAttribute = attribute
    menu.refresh()
    try await source.waitForReads(2)
    #expect(menu.appleMenu == apple)
    #expect(menu.items == items)

    source.failedAttribute = nil
    source.title = "Recovered"
    source.allowRetry()
    await menu.readTask?.value
    #expect(menu.appleMenu == apple)
    #expect(menu.items.map(\.title) == ["Recovered", "File"])
    #expect(source.reads == [100, 100, 100])
}

@Test @MainActor func menuRecoversWhenItsFirstReadFails() async throws {
    let source = MenuReadFixture()
    source.failedAttribute = kAXMenuBarAttribute
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read, sleep: source.sleep)
    menu.read(MenuApplication(pid: 100))
    try await source.waitForReads(1)
    #expect(menu.items.isEmpty)
    source.failedAttribute = nil
    source.allowRetry()
    await menu.readTask?.value
    #expect(menu.appleMenu?.title == "Apple")
    #expect(menu.items.map(\.title) == ["First", "File"])
}

@Test(arguments: [false, true])
@MainActor func switchingAppsCancelsThePreviousMenuRetry(secondReadFails: Bool) async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read, sleep: source.sleep)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    source.failedAttribute = kAXMenuBarAttribute
    menu.refresh()
    try await source.waitForReads(2)
    let previousRetry = menu.readTask
    source.failedAttribute = secondReadFails ? kAXMenuBarAttribute : nil
    source.title = "Second"
    menu.read(MenuApplication(pid: 200))
    try await source.waitForReads(3)
    source.failedAttribute = nil
    source.allowRetry()
    await previousRetry?.value
    await menu.readTask?.value
    #expect(menu.items.map(\.title) == ["Second", "File"])
    #expect(source.reads == (secondReadFails ? [100, 100, 200, 200] : [100, 100, 200]))
}

@Test @MainActor func disablingMenusCancelsRecoveryAndClearsThem() async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read, sleep: source.sleep)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    source.failedAttribute = kAXMenuBarAttribute
    menu.refresh()
    try await source.waitForReads(2)
    let retry = menu.readTask
    menu.read(nil)
    source.failedAttribute = nil
    await retry?.value
    await menu.readTask?.value
    #expect(menu.appleMenu == nil)
    #expect(menu.items.isEmpty)
    #expect(source.reads == [100, 100])
}

@Test @MainActor func revokingAccessDuringMenuRecoveryClearsTheMenus() async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read, sleep: source.sleep)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    source.failedAttribute = kAXMenuBarAttribute
    menu.refresh()
    try await source.waitForReads(2)
    source.trusted = false
    source.allowRetry()
    await menu.readTask?.value
    #expect(!menu.isTrusted)
    #expect(menu.appleMenu == nil)
    #expect(menu.items.isEmpty)
    #expect(source.reads == [100, 100])
}

@Test @MainActor func comingBackToStableBarAfterAllowingAccessReadsThePreviousAppsMenus() async {
    let source = MenuReadFixture()
    source.trusted = false
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    #expect(!menu.isTrusted)
    source.trusted = true
    menu.read(NSRunningApplication.current)
    await menu.readTask?.value
    #expect(menu.isTrusted)
    #expect(menu.items.map(\.title) == ["First", "File"])
    #expect(source.reads == [100])
}

@Test @MainActor func aSuccessfulEmptyMenuReadClearsPreviousMenusWithoutRetrying() async {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    source.empty = true
    menu.refresh()
    await menu.readTask?.value
    #expect(menu.appleMenu == nil)
    #expect(menu.items.isEmpty)
    #expect(source.reads == [100, 100])
}

@Test @MainActor func menuRecoveryStopsAfterFourRetries() async {
    let source = MenuReadFixture()
    source.failedAttribute = kAXMenuBarAttribute
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    #expect(source.reads == [100, 100, 100, 100, 100])
}

/// A background agent such as Logitech G HUB's can come to the front without a menu bar; macOS keeps showing the
/// previous app's menus, and so must the bar (#443).
@Test @MainActor func appMenusFollowTheMenuBarAppWhileAnAgentIsInFront() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"widgets":[{"id":"menus","type":"appMenu","position":"left"}]}"#.utf8).write(to: root)
    let source = MenuReadFixture()
    let store = BarStore(configurationURL: root,
                         appMenu: AppMenu(checkAccess: { source.trusted }, readAttribute: source.read, sleep: source.sleep))
    defer { store.stop() }
    var owner = MenuApplication(pid: 100, bundleID: "com.apple.finder")
    var ownerChanged: (@MainActor () -> Void)?
    store.activeApp = MenuApplication(pid: 200, bundleID: "com.logi.ghub.agent")
    store.menuBarApp = { owner }
    store.observeMenuBarApp = { changed in
        ownerChanged = changed
        return NSObject()
    }
    store.start()
    await store.appMenu.readTask?.value
    #expect(source.reads == [100])
    #expect(store.appMenu.appleMenu?.title == "Apple")
    #expect(store.appMenu.items.map(\.title) == ["First", "File"])

    owner = MenuApplication(pid: 300, bundleID: "com.apple.Safari")
    let changeOwner = try #require(ownerChanged)
    changeOwner()
    await store.appMenu.readTask?.value
    #expect(source.reads == [100, 300])
}

@Test @MainActor func appleMenuKeepsItsIconWhenTheSourceAppChanges() throws {
    let appMenu = AppMenu()
    func image(title: String, pid: pid_t) throws -> CGImage {
        let item = AppMenuItem(title: title, element: AXUIElementCreateApplication(pid))
        let renderer = ImageRenderer(content: AppMenuView(appMenu: appMenu, items: [item], isAppleMenu: true,
            appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()), padding: EdgeInsets(), open: { _, _ in }, requestAccess: {}))
        return try #require(renderer.cgImage)
    }
    let first = try image(title: "Apple", pid: 1)
    let second = try image(title: "Another app's Apple menu", pid: 2)
    #expect(first.width == second.width)
    #expect(first.height == second.height)
    #expect(first.dataProvider?.data == second.dataProvider?.data)
}

@Test @MainActor func appMenuReportsExpansionAndReturnsToItsCollapsedWidth() async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    var expanded: Bool?
    func content(hovering: Bool) -> AppMenuView {
        AppMenuView(appMenu: menu, items: menu.items, expandOnHover: true, hovering: hovering, expanded: hovering,
                    appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()),
                    padding: EdgeInsets(), open: { _, _ in }, requestAccess: {}) { expanded = $0 }
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 40),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: content(hovering: false))
    window.contentView = host
    var widths: [CGFloat] = []
    for hovering in [false, true, false] {
        host.rootView = content(hovering: hovering)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if expanded == hovering { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(expanded == hovering)
        widths.append(host.fittingSize.width)
    }
    #expect(widths[1] > widths[0])
    #expect(abs(widths[2] - widths[0]) < 0.5)
    #expect(!window.isVisible)
}

private final class BundledApplication: NSRunningApplication, @unchecked Sendable {
    let url: URL
    override var bundleURL: URL? { url }
    override var bundleIdentifier: String? { nil }

    init(url: URL) {
        self.url = url
        super.init()
    }
}

/// An app bundle at `path` under `directory` whose Info.plist holds `info`.
private func makeApp(_ path: String, in directory: URL, info: [String: String] = [:]) throws -> URL {
    let app = directory.appending(path: path)
    try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: info.merging(["CFBundlePackageType": "APPL"]) { $1 }, format: .xml, options: 0)
        .write(to: app.appending(path: "Contents/Info.plist"))
    return app
}

@Test func menuBarItemsUseTheIconOfTheAppAroundAProcessWithoutOne() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try makeApp("Tool.app", in: directory, info: ["CFBundleIconFile": "AppIcon"])
    let helper = try makeApp("Tool.app/Contents/Library/Helper.app", in: directory)
    let agent = try makeApp("Agent.app", in: directory)
    #expect(iconBundle(containing: app)?.path == app.path)
    #expect(iconBundle(containing: helper)?.path == app.path)
    #expect(iconBundle(containing: app.appending(path: "Contents/Resources/daemon/tool"))?.path == app.path)
    #expect(iconBundle(containing: agent) == nil)
    #expect(iconBundle(containing: nil) == nil)
}

@Test func menuBarItemsShowSymbolsForMacOSItemsAndAgentsWithoutIcons() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let agent = BundledApplication(url: try makeApp("Agent.app", in: directory))
    func symbol(_ name: String) -> Data? { NSImage(systemSymbolName: name, accessibilityDescription: nil)?.tiffRepresentation }
    #expect(menuBarIcon(identifier: "com.apple.menuextra.wifi", app: agent).tiffRepresentation == symbol("wifi"))
    #expect(menuBarIcon(identifier: "com.apple.menuextra.bluetooth", app: agent).accessibilityDescription == "Bluetooth")
    #expect(menuBarIcon(identifier: nil, app: agent).tiffRepresentation == symbol("menubar.rectangle"))
    let icon = menuBarIcon(identifier: nil, app: BundledApplication(url: try makeApp("Tool.app", in: directory, info: ["CFBundleIconFile": "AppIcon"])))
    #expect(!icon.isTemplate)
    #expect(icon.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 36)
}

@Test func menuBarItemsGoWhereTheirReferencesPutThem() {
    func item(_ title: String, app: String, bundleID: String?, identifier: String? = nil) -> MenuBarItem {
        MenuBarItem(entry: AppMenuEntry(title: title, element: AXUIElementCreateApplication(1), isEnabled: true, isChecked: false, hasSubmenu: false),
                    bundleID: bundleID, appName: app, identifier: identifier)
    }
    let wifi = item("Wi‑Fi", app: "Control Center", bundleID: "com.apple.controlcenter", identifier: "com.apple.menuextra.wifi")
    let battery = item("Battery", app: "Control Center", bundleID: "com.apple.controlcenter", identifier: "com.apple.menuextra.battery")
    let granola = item("Granola", app: "Granola", bundleID: "com.granola.app")
    let docker = item("Docker Desktop", app: "Docker Desktop", bundleID: nil)
    let items = [docker, granola, wifi, battery]
    let batteryReference = MenuBarItemReference(app: "com.apple.controlcenter", item: "Battery")
    let granolaReference = MenuBarItemReference(app: "Granola", item: nil)
    #expect(items.filter(batteryReference.matches).map(\.entry.title) == ["Battery"])
    #expect(items.filter(granolaReference.matches).map(\.entry.title) == ["Granola"])
    #expect(items.filter(MenuBarItemReference(app: "Control Center", item: nil).matches).map(\.entry.title) == ["Wi‑Fi", "Battery"])

    let shown: [MenuBarItemsEntry] = [.item(batteryReference), .item(granolaReference), .symbol]
    func value(_ entries: [MenuBarItemsEntry]) -> ConfigurationValue { .array(entries.map(\.configurationValue)) }
    let wifiReference = MenuBarItemReference(app: "com.apple.controlcenter", item: "com.apple.menuextra.wifi")
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .item(wifi), to: .bar, before: 1, among: items) == [
        "shown": value([shown[0], .item(wifiReference), shown[1], .symbol])
    ])
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .item(granola), to: .hidden, before: nil, among: items) == [
        "hidden": value([.item(MenuBarItemReference(app: "com.granola.app", item: nil))])
    ])
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .shown(0), to: .bar, before: 2, among: items) == [
        "shown": value([shown[1], shown[0], .symbol])
    ])
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .shown(2), to: .bar, before: 0, among: items) == [
        "shown": value([.symbol, shown[0], shown[1]])
    ])
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .shown(2), to: .hidden, before: nil, among: items) == [
        "shown": value([shown[0], shown[1]]), "hidden": value([.symbol])
    ])
    var symbol = granolaReference
    symbol.icon = "waveform"
    #expect(menuBarItemsProperties(shown: [shown[0], .item(symbol)], hidden: [], moving: .shown(1), to: .hidden, before: nil, among: items) == [
        "shown": value([shown[0]]), "hidden": value([.item(symbol)])
    ])
    #expect(menuBarItemsProperties(shown: [], hidden: [.item(MenuBarItemReference(app: "Docker Desktop", item: nil))], moving: .hidden(0),
                                   to: .row, before: nil, among: items) == ["hidden": .array([])])
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .shown(0), to: .bar, before: nil, among: items).isEmpty)
    #expect(menuBarItemsProperties(shown: shown, hidden: [], moving: .item(docker), to: .row, before: nil, among: items).isEmpty)
}

/// Accessibility elements made up for a test, each an application element with its own process ID, and their attributes.
private final class AccessibilityTree: @unchecked Sendable {
    private var attributes: [(element: AXUIElement, values: [String: CFTypeRef])] = []

    @discardableResult
    func add(_ pid: pid_t, role: String, children: [AXUIElement] = [], _ values: [String: CFTypeRef] = [:]) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        attributes.append((element, values.merging([kAXRoleAttribute: role as CFString, kAXChildrenAttribute: children as CFArray]) { $1 }))
        return element
    }

    func read(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        attributes.first { CFEqual($0.element, element) }?.values[name]
    }
}

@Test func macOS27ReadsMenuBarItemsFromTheActiveMenuBarThatMenuBarAgentDraws() async {
    let tree = AccessibilityTree()
    func slot(_ pid: pid_t, holding item: AXUIElement) -> AXUIElement { tree.add(pid, role: kAXGroupRole, children: [item]) }
    func hosted(_ pid: pid_t, _ item: AXUIElement) -> AXUIElement { tree.add(pid, role: kAXGroupRole, children: [item], [kAXSubroleAttribute: "AXHostingView" as CFString]) }
    let wifiValues = [kAXIdentifierAttribute: "com.apple.menuextra.wifi" as CFString, kAXDescriptionAttribute: "Wi‑Fi" as CFString]
    let wifi = tree.add(8011, role: kAXMenuBarItemRole, wifiValues)
    let raycast = tree.add(955, role: kAXButtonRole)
    let timesheet = tree.add(981, role: kAXButtonRole, [kAXDescriptionAttribute: "Timesheet" as CFString])
    let inactive = tree.add(5001, role: kAXWindowRole, children: [
        slot(6001, holding: tree.add(957, role: kAXApplicationRole)),
        slot(6002, holding: hosted(7002, tree.add(8002, role: kAXMenuBarItemRole, wifiValues))),
    ])
    let active = tree.add(5002, role: kAXWindowRole, children: [
        slot(6011, holding: hosted(7011, wifi)), slot(6012, holding: raycast), slot(6013, holding: timesheet), tree.add(6014, role: kAXGroupRole),
    ])
    tree.add(721, role: kAXApplicationRole, [kAXWindowsAttribute: [tree.add(5000, role: kAXWindowRole), inactive, active] as CFArray])

    let items = await foundMenuBarItems(apps: [721, 955, 981], agent: 721, readAttribute: tree.read).sorted { $0.pid < $1.pid }
    #expect(items.map(\.pid) == [721, 955, 981])
    #expect(items.map(\.element) == [wifi, raycast, timesheet])
    #expect(items.map(\.identifier) == ["com.apple.menuextra.wifi", nil, nil])
    #expect(items.map(\.description) == ["Wi‑Fi", nil, "Timesheet"])
}

@Test(arguments: [false, true])
func beforeMacOS27MenuBarItemsComeFromEachAppsOwnList(withMenuBarAgent: Bool) async {
    let tree = AccessibilityTree()
    let wifi = tree.add(8001, role: kAXMenuBarItemRole,
                        [kAXIdentifierAttribute: "com.apple.menuextra.wifi" as CFString, kAXDescriptionAttribute: "Wi‑Fi" as CFString])
    let docker = tree.add(8002, role: kAXMenuBarItemRole, children: [tree.add(8003, role: kAXMenuRole)])
    tree.add(724, role: kAXApplicationRole, [kAXExtrasMenuBarAttribute: tree.add(7001, role: kAXMenuBarRole, children: [wifi])])
    tree.add(955, role: kAXApplicationRole, [kAXExtrasMenuBarAttribute: tree.add(7002, role: kAXMenuBarRole, children: [docker])])
    tree.add(721, role: kAXApplicationRole, [kAXWindowsAttribute: [tree.add(5000, role: kAXWindowRole)] as CFArray])

    let items = await foundMenuBarItems(apps: [724, 955], agent: withMenuBarAgent ? 721 : nil, readAttribute: tree.read).sorted { $0.pid < $1.pid }
    #expect(items.map(\.pid) == [724, 955])
    #expect(items.map(\.element) == [wifi, docker])
    #expect(items.map(\.identifier) == ["com.apple.menuextra.wifi", nil])
    #expect(items.map(\.description) == ["Wi‑Fi", nil])
    #expect(items.map(\.hasMenu) == [false, true])
}

/// CodexBar draws its menu with SwiftUI: a row of provider buttons without text, and a usage card that shows Accessibility
/// only its history submenu. StableBar can't draw either row, so the item opens CodexBar's own menu, while a row that draws
/// its text in child views, as Tailscale's do, keeps the menu in StableBar's popup.
@Test func menuBarItemsOpenTheAppsOwnMenuWhenARowHasNeitherTitleNorText() async {
    let tree = AccessibilityTree()
    func app(_ pid: pid_t, rows: [AXUIElement]) {
        let quit = tree.add(pid + 4000, role: kAXMenuItemRole, [kAXTitleAttribute: "Quit" as CFString])
        let item = tree.add(pid + 2000, role: kAXMenuBarItemRole, children: [tree.add(pid + 3000, role: kAXMenuRole, children: rows + [quit])])
        tree.add(pid, role: kAXApplicationRole, [kAXExtrasMenuBarAttribute: tree.add(pid + 1000, role: kAXMenuBarRole, children: [item])])
    }
    func text(_ pid: pid_t, _ value: String) -> AXUIElement { tree.add(pid, role: kAXStaticTextRole, [kAXValueAttribute: value as CFString]) }
    app(950, rows: [tree.add(9000, role: kAXMenuItemRole, children: [tree.add(9001, role: kAXButtonRole), tree.add(9002, role: kAXButtonRole)])])
    let history = tree.add(9011, role: kAXMenuRole, children: [tree.add(9012, role: kAXMenuItemRole, children: [text(9013, "Oct 27: $4.20")])])
    app(951, rows: [tree.add(9010, role: kAXMenuItemRole, children: [history])])
    app(952, rows: [tree.add(9020, role: kAXMenuItemRole, children: [tree.add(9021, role: kAXGroupRole, children: [text(9022, "Connected")])]),
                    tree.add(9023, role: kAXMenuItemRole, [kAXTitleAttribute: "" as CFString])])

    let items = await foundMenuBarItems(apps: [950, 951, 952], agent: nil, readAttribute: tree.read).sorted { $0.pid < $1.pid }
    #expect(items.map(\.hasMenu) == [false, false, true])
}

/// A row's title comes from the text it draws, never from its submenu's rows.
@Test @MainActor func appMenuRowsTakeNoTitleFromTheirSubmenu() {
    let tree = AccessibilityTree()
    func history(_ pid: pid_t) -> AXUIElement {
        tree.add(pid, role: kAXMenuRole, children: [tree.add(pid + 1, role: kAXMenuItemRole, children: [
            tree.add(pid + 2, role: kAXStaticTextRole, [kAXValueAttribute: "Oct 27: $4.20" as CFString]),
        ])])
    }
    let session = tree.add(9001, role: kAXStaticTextRole, [kAXValueAttribute: "Session 42%" as CFString])
    let item = tree.add(8000, role: kAXMenuBarItemRole, children: [tree.add(8001, role: kAXMenuRole, children: [
        tree.add(9000, role: kAXMenuItemRole, children: [session, history(9100)]),
        tree.add(9002, role: kAXMenuItemRole, children: [history(9200)]),
        tree.add(9003, role: kAXMenuItemRole, [kAXTitleAttribute: "Quit" as CFString]),
    ])])
    let menu = AppMenu(checkAccess: { true }, readAttribute: tree.read, readAttributes: { names, element in names.map { tree.read($0, element) } })
    guard case let .appMenu(entries) = menu.popup(forMenuBarItem: item).layout.content else {
        Issue.record("The popup isn't an app menu")
        return
    }
    #expect(entries.map(\.title) == ["Session 42%", "Quit"])
    #expect(entries.map(\.hasSubmenu) == [true, false])
}

@Test func macOS27FallsBackToMenuBarAgentsOwnListWhenItsWindowsHoldNoItems() async {
    let tree = AccessibilityTree()
    let clock = tree.add(8001, role: kAXMenuBarItemRole, [kAXIdentifierAttribute: "com.apple.menuextra.clock" as CFString])
    let hosting = tree.add(7001, role: kAXGroupRole, children: [clock], [kAXSubroleAttribute: "AXHostingView" as CFString])
    tree.add(721, role: kAXApplicationRole, [kAXExtrasMenuBarAttribute: tree.add(6001, role: kAXMenuBarRole, children: [hosting])])

    let items = await foundMenuBarItems(apps: [721], agent: 721, readAttribute: tree.read)
    #expect(items.map(\.pid) == [721])
    #expect(items.map(\.element) == [clock])
    #expect(items.map(\.identifier) == ["com.apple.menuextra.clock"])
}

@Test func macOS27KeepsMacOSOwnMenuBarItemsUnderControlCenter() {
    let agent = MenuApplication(pid: 721, bundleID: "com.apple.MenuBarAgent")
    let controlCenter = MenuApplication(pid: 724, bundleID: "com.apple.controlcenter")
    let raycast = MenuApplication(pid: 955)
    let apps: [pid_t: NSRunningApplication] = [721: agent, 724: controlCenter, 955: raycast]
    #expect(menuBarItemApp(pid: 721, in: apps) === controlCenter)
    #expect(menuBarItemApp(pid: 955, in: apps) === raycast)
    #expect(menuBarItemApp(pid: 999, in: apps) == nil)
    #expect(menuBarItemApp(pid: 721, in: [721: agent]) === agent)
}

@Test func menuBarSymbolsAreSystemSymbols() {
    #expect(menuBarSymbols.values.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }.isEmpty)
}

@Test func menuBarItemsDrawAppIconsFromTheirRetinaArt() throws {
    func art(_ color: NSColor, pixels: Int) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    /// The middle of `image` drawn at 1×, as on a 1× display.
    func color(drawing image: NSImage) throws -> NSColor {
        let canvas = try art(.clear, pixels: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        image.draw(in: NSRect(origin: .zero, size: canvas.size))
        NSGraphicsContext.restoreGraphicsState()
        return try #require(canvas.colorAt(x: 9, y: 9)?.usingColorSpace(.deviceRGB))
    }
    // A broken 1× image beside the Retina one, as in Docker Desktop's icon.
    let icon = NSImage(size: NSSize(width: 18, height: 18))
    icon.addRepresentation(try art(.red, pixels: 18))
    icon.addRepresentation(try art(.blue, pixels: 36))
    #expect(try color(drawing: icon).redComponent > 0.9)
    let retina = try color(drawing: retinaArt(of: icon))
    #expect(retina.blueComponent > 0.9 && retina.redComponent < 0.1)
}

/// Actual AppKit/SwiftUI rendering, in a window that is never ordered onto the user's screen.
@MainActor final class PresentationHostingView: NSHostingView<AnyView> {
    private(set) var layoutCalls = 0
    override func layout() { layoutCalls += 1; super.layout() }
}

@MainActor final class OffscreenBar {
    let panel: BarPanel
    let host: PresentationHostingView
    let store: BarStore
    let backingScale: CGFloat
    private let ownsStore: Bool
    let display: BarDisplay

    init(configuration: Configuration, display: BarDisplay, width: CGFloat, workspaces: [Workspace] = [],
         backingScale: CGFloat = 2, sharedStore: BarStore? = nil, appMenu: AppMenu = AppMenu()) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        self.backingScale = backingScale
        self.display = display
        ownsStore = sharedStore == nil
        store = sharedStore ?? BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                                        appMenu: appMenu)
        if sharedStore == nil {
            store.configuration = configuration
            store.workspaceStore.workspaces = workspaces
            store.preparePresentations()
        }
        let geometry = configuration.barGeometry(for: display)
        let top = (NSScreen.main?.frame.maxY ?? 900) - 40
        panel = BarPanel(contentRect: CGRect(x: 0, y: top - geometry.inputHeight, width: width, height: geometry.inputHeight),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.barGeometry = geometry
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        host = PresentationHostingView(rootView: AnyView(BarView(store: store, display: display, nativeDecorations: true)
            .frame(width: width, height: geometry.inputHeight)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, backingScale)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.sizingOptions = []
        panel.contentView = host
    }

    func settle() async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func refreshGeometry() {
        guard let configuration = store.configuration else { return }
        let geometry = configuration.barGeometry(for: display)
        let top = panel.frame.maxY
        panel.barGeometry = geometry
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - geometry.inputHeight, width: panel.frame.width,
                              height: geometry.inputHeight), display: false)
        host.rootView = AnyView(BarView(store: store, display: display, nativeDecorations: true)
            .frame(width: panel.frame.width, height: geometry.inputHeight)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, backingScale)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
    }

    func bitmap(scale: CGFloat? = nil, name: String? = nil) throws -> NSBitmapImageRep {
        let scale = scale ?? backingScale
        let size = panel.drawingFrame.size
        func blank(_ size: CGSize) throws -> NSBitmapImageRep {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            return bitmap
        }
        let bitmap = try blank(size)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.interpolationQuality = .none
        let bar = try blank(host.bounds.size)
        host.cacheDisplay(in: host.bounds, to: bar)
        context.draw(try #require(bar.cgImage), in: CGRect(x: 0, y: size.height - host.bounds.height,
            width: size.width, height: host.bounds.height))
        if let decoration = panel.decorationPanel?.contentView {
            decoration.layoutSubtreeIfNeeded()
            let layer = try blank(decoration.bounds.size)
            decoration.cacheDisplay(in: decoration.bounds, to: layer)
            context.draw(try #require(layer.cgImage), in: CGRect(origin: .zero, size: size))
        }
        if let name, let output = ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"] {
            let directory = URL(filePath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
        }
        return bitmap
    }

    func anchors(_ id: String) -> [NSView] {
        func find(_ view: NSView) -> [NSView] {
            (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap(find)
        }
        return find(host)
    }

    func close() { if ownsStore { store.stop() }; panel.contentView = nil; panel.close() }

}

private func indicatorConfiguration(gap: Int, scale: Double = 1, placement: String = "belowBar", cellHeight: Int = 22) throws -> Configuration {
    try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"bar":{"height":38,"inset":12,"spacing":0,"displayScale":{"external":\##(scale)},"style":{"background":"#101010"}},
      "defaults":{"foreground":"#ffffff","fontSize":13,"paddingHorizontal":0,"paddingVertical":0},
      "widgets":[{"id":"spaces","type":"workspaces","position":"left","workspace":{
        "showEmpty":true,"showApps":false,"indicator":"underline","style":{"height":\##(cellHeight),"width":36},
        "indicatorStyle":{"placement":"\##(placement)","height":2,"background":"#ff00ff","offsetY":\##(gap)}
      }}]}
    """##.utf8))
}

@Test @MainActor func nativeBelowBarRenderingHasExactGapAndHeightWithStableLabelsAndClickThrough() async throws {
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    for scale in [1.0, 1.5, 2.0] {
        for gap in [0, 3] {
            let configuration = try indicatorConfiguration(gap: gap, scale: scale)
            let fixture = OffscreenBar(configuration: configuration, display: display, width: 300, workspaces: [
                Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1),
                Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1)
            ])
            defer { fixture.close() }
            await fixture.settle()
            let geometry = configuration.barGeometry(for: display)
            #expect(abs(fixture.panel.frame.height - 38 * scale) < 0.01)
            #expect(fixture.panel.drawingFrame.height == geometry.panelHeight)
            let bitmap = try fixture.bitmap(name: "underline-gap\(gap)-scale\(scale)")
            let anchors = fixture.anchors("spaces")
            try #require(anchors.count == 1) // the measuring copy emits no popup anchor
            let bounds = anchors[0].convert(anchors[0].bounds, to: fixture.host)
            #expect(abs(bounds.minX - 12 * scale) < 0.01)
            #expect(abs(bounds.width - 78 * scale) < 0.01)
            var pixels: [(Int, Int)] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1 { pixels.append((x, y)) }
                }
            }
            #expect(!pixels.isEmpty)
            #expect(pixels.map(\.1).min() == Int((38 + CGFloat(gap)) * scale * 2))
            #expect(pixels.map(\.1).max() == Int((40 + CGFloat(gap)) * scale * 2) - 1)
            #expect(pixels.map(\.0).min() == Int(12 * scale * 2))
            #expect(pixels.map(\.0).max() == Int(48 * scale * 2) - 1)
            // The actual native decoration window always ignores input; the bar's own
            // strip-sized window still receives its background menu and widget events.
            let decoration = try #require(fixture.panel.decorationPanel)
            #expect(decoration.ignoresMouseEvents)
            #expect(!fixture.panel.ignoresMouseEvents)
            #expect(decoration.frame == fixture.panel.drawingFrame)
            #expect(!fixture.panel.frame.contains(CGPoint(x: decoration.frame.midX, y: decoration.frame.minY + 0.25)))
            #expect(!fixture.panel.isVisible && !decoration.isVisible)
            let before = fixture.panel.frame
            fixture.store.workspaceStore.workspaces = [
                Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1),
                Workspace(name: "2", isFocused: true, isVisible: true, monitor: 1)
            ]
            await fixture.settle()
            #expect(fixture.panel.frame == before)
            #expect(anchors[0].convert(anchors[0].bounds, to: fixture.host) == bounds)
        }
    }
}

@Test func decorationBoundsReserveNestedStateCombinationsAndRespectMarginsAndViewports() throws {
    let style = try JSONDecoder().decode(WidgetStyle.self, from: Data(#"""
    {"placement":"cell","height":2,"states":{
      "focused":{"placement":"belowBar","height":3},
      "mode":{"offsetY":4,"states":{"mode.command":{"height":5}}}}}
    """#.utf8))
    #expect(style.maximumOutsideExtent == 9)
    let geometry = BarGeometry(layoutHeight: 38, margin: 3, outsideExtent: 9)
    #expect(geometry.panelHeight == 44)
    #expect(geometry.visibleRect(width: 300) == CGRect(x: 3, y: 3, width: 294, height: 32))
    let rect = belowBarIndicatorRect(cell: CGRect(x: -10, y: 5, width: 50, height: 22),
        widget: CGRect(x: -20, y: 0, width: 300, height: 38), viewport: CGRect(x: 12, y: 0, width: 25, height: 38),
        visibleBar: CGRect(x: 0, y: 0, width: 300, height: 38),
        style: WidgetStyle(height: 2, offsetY: 3), scale: 1, pixelsPerPoint: 2)
    #expect(rect == CGRect(x: 12, y: 41, width: 25, height: 2))
    let offscreen = belowBarIndicatorRect(cell: CGRect(x: -50, y: 5, width: 20, height: 22),
        widget: CGRect(x: -60, y: 0, width: 300, height: 38), viewport: CGRect(x: 12, y: 0, width: 25, height: 38),
        visibleBar: CGRect(x: 0, y: 0, width: 300, height: 38), style: WidgetStyle(), scale: 1, pixelsPerPoint: 1)
    #expect(offscreen == nil)
    #expect(popupAttachmentTop(anchor: CGRect(x: -1000, y: 800, width: 40, height: 22),
        window: CGRect(x: -1500, y: 780, width: 1512, height: 44), geometry: geometry) == 780)
    #expect(popupAttachmentTop(anchor: CGRect(x: 100, y: 1700, width: 40, height: 22),
        window: CGRect(x: 0, y: 1680, width: 2560, height: 44), geometry: geometry) == 1680)
    #expect(popupAttachmentTop(anchor: CGRect(x: 100, y: 1690, width: 40, height: 22),
        window: CGRect(x: 0, y: 1682, width: 2560, height: 38),
        geometry: BarGeometry(layoutHeight: 38, margin: 3, outsideExtent: 0)) == 1685)
}

@Test @MainActor func nativeConstrainedWorkspaceClipsItsDecorationAndScrollingRemovesOffscreenSelection() async throws {
    let json = ##"""
    {"bar":{"height":38,"inset":12,"spacing":4,"style":{"background":"#101010"}},
     "defaults":{"foreground":"#ffffff","paddingHorizontal":0,"paddingVertical":0},"widgets":[
      {"id":"spaces","type":"workspaces","position":"left","overflow":"never","workspace":{
        "showEmpty":true,"showApps":false,"indicator":"underline","style":{"width":36},
        "indicatorStyle":{"placement":"belowBar","height":2,"background":"#ff00ff"}}},
      {"id":"extra","type":"text","text":"A long optional label that must overflow","position":"right"}]}
    """##
    let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    var workspaces: [Workspace] = []
    for index in 1...9 {
        workspaces.append(Workspace(name: String(index), isFocused: index == 1, isVisible: index == 1, monitor: 1))
    }
    let fixture = OffscreenBar(configuration: config, display: display, width: 70, workspaces: workspaces)
    defer { fixture.close() }
    await fixture.settle()
    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    let scroll = try #require(scrolls(fixture.host).first)
    #expect(fixture.anchors("spaces").count == 1)
    #expect(fixture.anchors("extra").isEmpty) // overflowed widgets have no visible anchor
    let before = try fixture.bitmap(name: "constrained-before-scroll")
    func magentaX(_ bitmap: NSBitmapImageRep) -> [Int] {
        (0..<bitmap.pixelsWide).filter { x in
            guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1
        }
    }
    #expect(!magentaX(before).isEmpty)
    let workspaceRegion = scroll.convert(scroll.bounds, to: fixture.host)
    #expect(workspaceRegion.width < 36)
    #expect(magentaX(before).max() == Int(workspaceRegion.maxX * 2) - 1)
    scroll.contentView.scroll(to: CGPoint(x: 100, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    await fixture.settle()
    let after = try fixture.bitmap(name: "constrained-after-scroll")
    #expect(magentaX(after).isEmpty)
    #expect(abs(fixture.panel.frame.height - 38) < 0.01)
    #expect(fixture.panel.drawingFrame.height == 40)
}

@Test @MainActor func nativeOutlineStaysInsideTheVisibleStripAndBottomDefaultIsUnchanged() async throws {
    for edges in ["bottom", "all"] {
        let json = ##"{"bar":{"height":38,"margin":3,"style":{"background":"#101010","borderColor":"#ff00ff","borderWidth":1,"borderEdges":"\##(edges)","cornerRadius":4}},"widgets":[]}"##
        let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        let fixture = OffscreenBar(configuration: config, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 100)
        defer { fixture.close() }
        await fixture.settle()
        let bitmap = try fixture.bitmap(name: "border-\(edges)")
        func isBorder(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.2 && color.alphaComponent > 0.8
        }
        #expect(isBorder(100, 69))
        #expect(isBorder(100, 6) == (edges == "all"))
        #expect(isBorder(6, 38) == (edges == "all"))
        #expect(isBorder(193, 38) == (edges == "all"))
        #expect(!isBorder(100, 5))
        #expect(!isBorder(100, 70))
        #expect(fixture.panel.frame.height == 38)
    }
}

@Test @MainActor func fractionalScaleOnOneXDisplayReservesBothPixelRoundingSteps() async throws {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"bar":{"height":25,"displayScale":{"external":1.5},"style":{"background":"#101010"}},
      "defaults":{"paddingHorizontal":0,"paddingVertical":0},"widgets":[
       {"id":"spaces","type":"workspaces","position":"left","workspace":{"showApps":false,"indicator":"underline",
        "indicatorStyle":{"placement":"belowBar","height":1,"background":"#ff00ff"}}}]}
    """##.utf8))
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    let fixture = OffscreenBar(configuration: config, display: display, width: 200,
        workspaces: [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1)], backingScale: 1)
    defer { fixture.close() }
    await fixture.settle()
    #expect(config.barGeometry(for: display).panelHeight == 40)
    let image = try fixture.bitmap(name: "underline-half-pixel-one-x")
    var rows = Set<Int>()
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1 { rows.insert(y) }
        }
    }
    #expect(rows == [38, 39])
    #expect(fixture.panel.decorationPanel?.ignoresMouseEvents == true)
}

/// » opens only menus of the app that owns the menu bar, not titles left from the previous app.
/// App menus that read `titles` from the menu bar: the Apple menu, then the app's menus.
@MainActor private func appMenu(showing titles: [String]) async -> AppMenu {
    let menu = AppMenu(checkAccess: { true }, readAttribute: { name, element in
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch name {
        case kAXMenuBarAttribute: return AXUIElementCreateApplication(1)
        case kAXChildrenAttribute: return titles.indices.map { AXUIElementCreateApplication(pid_t(1000 + $0)) } as CFArray
        case kAXTitleAttribute: return titles[Int(pid) - 1000] as CFString
        default: return nil
        }
    }, sleep: { _ in })
    menu.read(MenuApplication(pid: 100))
    await menu.readTask?.value
    return menu
}

/// App menus squeezed beside a clock hide their last menus to fit. A widget `width` or `minWidth` keeps them from
/// getting narrower: squeezed below it, they move into More widgets instead of spilling over the clock.
@Test(arguments: [("{}", 300.0, false), (#"{"minWidth":300}"#, 300.0, true), (#"{"width":120}"#, 160.0, true)])
@MainActor func appMenusShrinkNoFurtherThanTheirWidgetsWidth(style: String, barWidth: Double, overflows: Bool) async throws {
    let menu = await appMenu(showing: ["Apple", "Xcode", "File", "Edit", "View", "Find", "Navigate", "Editor", "Product",
                                       "Debug", "Window", "Help"])
    try #require(menu.items.count == 11)
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"inset":10,"spacing":8},"widgets":[
      {"id":"menus","type":"appMenu","position":"left","style":\#(style)},
      {"id":"clock","type":"text","text":"12:00","position":"right","overflow":"never"}
    ]}
    """#.utf8))
    let fixture = OffscreenBar(configuration: configuration, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil),
                               width: barWidth, backingScale: 1, appMenu: menu)
    defer { fixture.close() }
    // The bar measures, plans and measures again over several layout passes: lay out until the anchors stay put for
    // three passes in a row, counting passes rather than time.
    var frames: [String: [CGRect]] = [:]
    var stable = 0
    var passes = 0
    while stable < 3 && passes < 200 {
        passes += 1
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
        let next = Dictionary(uniqueKeysWithValues: ["clock", "menus", BarView.moreWidgetsID].map { id in
            (id, fixture.anchors(id).map { $0.convert($0.bounds, to: fixture.host) })
        })
        stable = next == frames && next["clock"]?.isEmpty == false ? stable + 1 : 0
        frames = next
    }
    try #require(stable == 3)
    let clockStart = try #require(frames["clock"]?.first).minX
    let menus = frames["menus"] ?? []
    #expect(menus.isEmpty == overflows)
    for menus in menus { #expect(menus.maxX <= clockStart + 0.5) }
    #expect(frames[BarView.moreWidgetsID]?.isEmpty != overflows)
}

@Test @MainActor func overflowMenusOpenOnlyForTheMenuBarsApp() {
    let menu = AppMenu(checkAccess: { true }, readAttribute: { _, _ in nil }, sleep: { _ in })
    let window = AppMenuItem(title: "Window", element: AXUIElementCreateApplication(100))
    let help = AppMenuItem(title: "Help", element: AXUIElementCreateApplication(200))
    #expect(menu.overflowPopup(for: [window]) == nil)
    menu.read(MenuApplication(pid: 100))
    guard let popup = menu.overflowPopup(for: [window, help]), case let .appMenu(entries) = popup.layout.content else {
        Issue.record("No overflow popup for the menu bar's app")
        return
    }
    #expect(entries.map(\.title) == ["Window"])
    #expect(entries.allSatisfy { $0.hasSubmenu })
    #expect(menu.overflowPopup(for: [help]) == nil)
}
