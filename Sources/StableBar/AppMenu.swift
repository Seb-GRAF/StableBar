import AppKit
@preconcurrency import ApplicationServices
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct AppMenuItem: Hashable {
    let title: String
    let element: AXUIElement
}

struct AppMenuEntry {
    let title: String
    let element: AXUIElement
    let isEnabled: Bool
    let isChecked: Bool
    let hasSubmenu: Bool
    var shortcut: MenuShortcut? = nil
    var icon: NSImage? = nil
    var menuBarDisplay: CGDirectDisplayID? = nil
    /// Shown in place of the entry before it while Option is held, as macOS menus show an alternate.
    var isAlternate = false
}

@MainActor @Observable
final class AppMenu: NSObject {
    private(set) var appleMenu: AppMenuItem?
    private(set) var items: [AppMenuItem] = []
    private(set) var isTrusted: Bool
    var hidesAccessWarning = false
    @ObservationIgnored private let checkAccess: () -> Bool
    @ObservationIgnored private let readAttribute: @Sendable (String, AXUIElement) -> CFTypeRef?
    @ObservationIgnored private let readAttributes: @Sendable ([String], AXUIElement) -> [CFTypeRef?]
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var app: NSRunningApplication?
    @ObservationIgnored private var submenus: [PopupPanel] = []
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    @ObservationIgnored private var menuBarPresses = 0
    @ObservationIgnored private var revealedPresses = 0
    @ObservationIgnored private var pressedItem: AXUIElement?
    private(set) var menuBarItems: [MenuBarItem] = []
    @ObservationIgnored let mirror: MenuBarItemMirror
    @ObservationIgnored var hidesMenuBar = false {
        didSet { if hidesMenuBar != oldValue { setMenuBarHidden(hidesMenuBar) } }
    }

    init(checkAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         readAttribute: @escaping @Sendable (String, AXUIElement) -> CFTypeRef? = { name, element in
             var value: CFTypeRef?
             guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
             return value
         },
         readAttributes: @escaping @Sendable ([String], AXUIElement) -> [CFTypeRef?] = copyAttributes,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.checkAccess = checkAccess
        self.readAttribute = readAttribute
        self.readAttributes = readAttributes
        self.sleep = sleep
        isTrusted = checkAccess()
        mirror = MenuBarItemMirror(readAttribute: readAttribute)
        super.init()
        mirror.items = { [weak self] in self?.menuBarItems ?? [] }
    }

    func read(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier == ProcessInfo.processInfo.processIdentifier || app.bundleIdentifier == "org.stablebar.app" {
            if !isTrusted { refresh() }
            return
        }
        readTask?.cancel()
        self.app = app
        let sleep = sleep
        readTask = Task { [weak self] in
            do {
                for delay in [0, 250, 500, 1000, 2000] {
                    try await sleep(.milliseconds(delay))
                    guard let self else { return }
                    if try await readItems() { return }
                }
            } catch {}
        }
    }

    private func readItems() async throws -> Bool {
        isTrusted = checkAccess()
        var next: [AppMenuItem] = []
        if isTrusted, let app {
            let pid = app.processIdentifier
            let readAttribute = readAttribute
            let items = await Task.detached { () -> [AppMenuItem]? in
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.1)
                guard let menuBar = readAttribute(kAXMenuBarAttribute, element),
                      let children = readAttribute(kAXChildrenAttribute, menuBar as! AXUIElement) as? [AXUIElement] else { return nil }
                var items: [AppMenuItem] = []
                for item in children {
                    guard let title = readAttribute(kAXTitleAttribute, item) as? String else { return nil }
                    items.append(AppMenuItem(title: title, element: item))
                }
                return items
            }.value
            try Task.checkCancellation()
            guard let items else { return false }
            next = items
        }
        if next.first != appleMenu { appleMenu = next.first }
        if Array(next.dropFirst()) != items { items = Array(next.dropFirst()) }
        return true
    }

    func refresh() {
        read(app)
    }

    func popup(for item: AppMenuItem) -> PopupConfiguration? {
        guard belongsToMenuBarApp(item) else { return nil }
        return Self.popup(entries(of: item.element))
    }

    /// The popup » opens: the menus that don't fit, each opening its own menu. Titles left from the previous app,
    /// shown until the new app's menus are read, stay out of it.
    func overflowPopup(for items: [AppMenuItem]) -> PopupConfiguration? {
        let entries = items.filter(belongsToMenuBarApp).map { item in
            AppMenuEntry(title: item.title, element: item.element, isEnabled: true, isChecked: false, hasSubmenu: true)
        }
        return entries.isEmpty ? nil : Self.popup(entries)
    }

    private func belongsToMenuBarApp(_ item: AppMenuItem) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(item.element, &pid)
        return pid == app?.processIdentifier
    }

    /// The popup that shows a menu's entries.
    static func popup(_ entries: [AppMenuEntry]) -> PopupConfiguration {
        var popup = PopupConfiguration(style: WidgetStyle(paddingHorizontal: 5, paddingVertical: 5, spacing: 0, width: 260),
                                       layout: PopupBlock(content: .appMenu(entries)))
        popup.alignment = .leading
        return popup
    }

    /// What a menu's entries show, read from each item in one call: every Accessibility call is a round trip to the
    /// app, and Chromium apps answer slowly. Chrome's File menu took 16 ms to read with four separate reads per item,
    /// and 13 ms with them in one call.
    private static let entryAttributes = [
        kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXChildrenAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdModifiersAttribute, kAXIdentifierAttribute,
    ]

    private func entries(of element: AXUIElement) -> [AppMenuEntry] {
        guard let menu = submenu(of: element) else { return [] }
        var entries: [AppMenuEntry] = []
        var previous: MenuItemKey?
        for child in children(of: menu) {
            AXUIElementSetMessagingTimeout(child, 0.1)
            let values = readAttributes(Self.entryAttributes, child)
            guard values.count == Self.entryAttributes.count,
                  let title = values[0] as? String ?? text(in: child, readAttribute),
                  !title.isEmpty || entries.last?.title.isEmpty == false else { continue }
            let submenu = submenu(among: values[3] as? [AXUIElement] ?? [])
            let key = MenuItemKey(character: values[4] as? String, virtualKey: values[5] as? Int, glyph: values[6] as? Int,
                                  modifiers: values[7] as? Int ?? 0)
            entries.append(AppMenuEntry(title: title, element: child, isEnabled: values[1] as? Bool == true,
                                        isChecked: values[2] as? String != nil,
                                        hasSubmenu: submenu != nil,
                                        shortcut: MenuShortcut(character: key.character, virtualKey: key.virtualKey, glyph: key.glyph,
                                                               modifiers: key.modifiers),
                                        icon: icon(identifier: values[8] as? String, submenu: submenu),
                                        isAlternate: previous.map(key.isAlternate) ?? false))
            previous = key
        }
        if entries.last?.title.isEmpty == true { entries.removeLast() }
        return entries
    }

    /// The icon macOS 27 shows beside an item. Accessibility gives no images, but an item without an identifier of its own
    /// reports its action as one. Move & Resize and Full Screen Tile report none, so they go by the first action in their
    /// submenu, which follows a Halves heading in Move & Resize.
    private func icon(identifier: String?, submenu: AXUIElement?) -> NSImage? {
        guard #available(macOS 27, *) else { return nil }
        if let identifier { return appMenuIcon(identifier: identifier) }
        guard let submenu else { return nil }
        let action = children(of: submenu).prefix(2).lazy.compactMap { self.attribute(kAXIdentifierAttribute, of: $0) as? String }.first
        return action.flatMap { windowSubmenuSymbols[$0] }.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! }
    }

    private func submenu(of element: AXUIElement) -> AXUIElement? {
        submenu(among: children(of: element))
    }

    private func submenu(among children: [AXUIElement]) -> AXUIElement? {
        children.first { attribute(kAXRoleAttribute, of: $0) as? String == kAXMenuRole }
    }

    func openSubmenu<Content: View>(_ element: AXUIElement?, beside row: NSView, content: (PopupConfiguration) -> Content) {
        let window = row.window!
        closeSubmenus(after: window)
        guard let element else { return }
        let popup = Self.popup(entries(of: element))
        let host = NSHostingView(rootView: content(popup).frame(width: popup.style.width!))
        let frame = window.convertToScreen(row.convert(row.bounds, to: nil))
        let screen = window.screen!.visibleFrame
        let size = NSSize(width: popup.style.width!, height: min(host.fittingSize.height, screen.height - 16))
        let gap = popup.style.paddingHorizontal! + 4
        let x = frame.maxX + gap + size.width <= screen.maxX - 8 ? frame.maxX + gap : frame.minX - gap - size.width
        let panel = PopupPanel(contentRect: NSRect(x: x, y: max(frame.maxY + popup.style.paddingVertical! - size.height, screen.minY + 8),
                                                   width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "App submenu"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = window.level
        panel.collectionBehavior = window.collectionBehavior
        panel.appearance = window.appearance
        panel.contentView = host
        (submenus.first?.parent ?? window).addChildWindow(panel, ordered: .above)
        submenus.append(panel)
    }

    func closeSubmenus(after window: NSWindow?) {
        let kept = submenus.firstIndex { $0 === window }.map { $0 + 1 } ?? 0
        for panel in submenus[kept...] {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        submenus.removeSubrange(kept...)
    }

    func openControlCenter() {
        guard checkAccess() else { return requestAccessibility() }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first,
              !showsPanel(app.processIdentifier) else { return }
        // Control Center lists the item up to macOS 26, MenuBarAgent from macOS 27 on.
        let owners = [app] + NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentID)
        let readAttribute = readAttribute
        let items = owners.lazy.flatMap { self.extras(of: $0.processIdentifier) }.map { menuBarExtra($0, readAttribute) }
        guard let item = items.first(where: { self.attribute(kAXIdentifierAttribute, of: $0) as? String == "com.apple.menuextra.controlcenter" }),
              let display = menuBarDisplay(of: frame(of: item, readAttribute)) else { return }
        pressInMenuBar(item, on: display)
    }

    func popup(forMenuBarItem element: AXUIElement) -> PopupConfiguration {
        Self.popup(entries(of: element))
    }

    func readMenuBarItems(requestingAccess: Bool) async -> Bool {
        guard checkAccess() else {
            if requestingAccess { requestAccessibility() }
            return false
        }
        guard revealedPresses == 0 else { return true }
        let apps = runningAppsByPID(NSWorkspace.shared.runningApplications, leavingOut: ProcessInfo.processInfo.processIdentifier)
        let items = await foundMenuBarItems(apps: Array(apps.keys),
                                            agent: apps.values.first { $0.bundleIdentifier == menuBarAgentID }?.processIdentifier,
                                            readAttribute: readAttribute)
        menuBarItems = items.sorted { $0.frame.midX < $1.frame.midX }.compactMap { item in
            guard let app = menuBarItemApp(pid: item.pid, in: apps), let display = menuBarDisplay(of: item.frame) else { return nil }
            // Time Machine's item has neither an identifier nor a description, and SystemUIServer, which draws it, has no other such item.
            let timeMachine = app.bundleIdentifier == "com.apple.systemuiserver" && item.identifier == nil && item.description == nil
            let identifier = timeMachine ? "com.apple.menuextra.TimeMachine" : item.identifier
            let title = timeMachine ? "Time Machine" : item.description ?? app.localizedName ?? ""
            return MenuBarItem(entry: AppMenuEntry(title: title, element: item.element, isEnabled: true, isChecked: false, hasSubmenu: item.hasMenu,
                                                   icon: menuBarIcon(identifier: identifier, app: app), menuBarDisplay: display),
                               bundleID: app.bundleIdentifier, appName: app.localizedName ?? "", identifier: identifier)
        }
        return true
    }

    /// The row of menu bar items, or nil without Accessibility access, which it asks for if `requestingAccess`.
    func menuBarItemsPopup(leavingOut references: [MenuBarItemReference], requestingAccess: Bool = true) async -> PopupConfiguration? {
        guard await readMenuBarItems(requestingAccess: requestingAccess) else { return nil }
        let items = menuBarItems.filter { item in !references.contains { $0.matches(item) } }
        return PopupConfiguration(style: WidgetStyle(paddingHorizontal: 5, paddingVertical: 5, spacing: 0, width: Double(items.count * 28 + 10)),
                                  layout: PopupBlock(content: .menuBarItems(items)))
    }

    func press(_ entry: AppMenuEntry) {
        let element = entry.element
        if let display = entry.menuBarDisplay {
            pressInMenuBar(element, on: display)
        } else {
            Task.detached { AXUIElementPerformAction(element, kAXPressAction as CFString) }
        }
    }

    func press(_ reference: MenuBarItemReference) {
        Task {
            guard await readMenuBarItems(requestingAccess: true), let item = menuBarItems.first(where: reference.matches) else { return }
            press(item.entry)
        }
    }

    func pressUnlessOpen(_ entry: AppMenuEntry) {
        var pid: pid_t = 0
        AXUIElementGetPid(entry.element, &pid)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == menuBarAgentID,
           let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            pid = controlCenter.processIdentifier
        }
        if let pressedItem, CFEqual(pressedItem, entry.element), showsPanel(pid) { return }
        pressedItem = entry.element
        press(entry)
    }

    private func pressInMenuBar(_ item: AXUIElement, on display: CGDirectDisplayID) {
        let top = CGDisplayBounds(display).minY
        let readAttribute = readAttribute, sleep = sleep
        Task {
            if await Task.detached(operation: { menuBarShows(on: display) }).value {
                Task.detached { AXUIElementPerformAction(item, kAXPressAction as CFString) }
                return
            }
            menuBarPresses += 1
            revealedPresses += 1
            let press = menuBarPresses
            setMenuBarHidden(true)
            setMenuBarShown(true, on: display)
            await Task.detached {
                for _ in 0..<25 {
                    if menuBarShows(on: display), frame(of: item, readAttribute).minY >= top { break }
                    try? await sleep(.milliseconds(20))
                }
                AXUIElementPerformAction(item, kAXPressAction as CFString)
            }.value
            setMenuBarShown(false, on: display)
            await Task.detached {
                var hiddenChecks = 0
                while hiddenChecks < 2 {
                    hiddenChecks = menuBarShows(on: display) ? 0 : hiddenChecks + 1
                    try? await sleep(.milliseconds(100))
                }
            }.value
            revealedPresses -= 1
            if press == menuBarPresses, !hidesMenuBar { setMenuBarHidden(false) }
        }
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        return readAttribute(name, element)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private func extras(of pid: pid_t) -> [AXUIElement] {
        attribute(kAXExtrasMenuBarAttribute, of: AXUIElementCreateApplication(pid)).map { children(of: $0 as! AXUIElement) } ?? []
    }
}

struct MenuBarItem {
    let entry: AppMenuEntry
    let bundleID: String?
    let appName: String
    let identifier: String?

    /// Names the item among those in the menu bar.
    var key: String { "\(bundleID ?? appName) \(identifier ?? entry.title)" }
}

/// How a menu bar item on the bar draws: its app's icon, or a copy of the item as macOS draws it.
enum MenuBarItemDisplay: String, Decodable, Sendable {
    case icon, live
}

struct MenuBarItemReference: Decodable, Equatable, Sendable {
    let app: String
    var item: String?
    var icon: String?
    var display: MenuBarItemDisplay?

    enum CodingKeys: String, CodingKey, CaseIterable { case app, item, icon, display }

    init(app: String, item: String?) {
        self.app = app
        self.item = item
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        app = try values.decode(String.self, forKey: .app)
        item = try values.decodeIfPresent(String.self, forKey: .item)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        display = try values.decodeIfPresent(MenuBarItemDisplay.self, forKey: .display)
    }

    func matches(_ item: MenuBarItem) -> Bool {
        (app == item.bundleID || app == item.appName) && (self.item == nil || self.item == item.identifier || self.item == item.entry.title)
    }

    var configurationValue: ConfigurationValue {
        var value: [String: ConfigurationValue] = ["app": .string(app)]
        if let item { value["item"] = .string(item) }
        if let icon { value["icon"] = .string(icon) }
        if let display { value["display"] = .string(display.rawValue) }
        return .object(value)
    }
}

enum MenuBarItemsEntry: Decodable, Equatable, Sendable {
    case item(MenuBarItemReference)
    case symbol

    init(from decoder: Decoder) throws {
        guard let name = try? decoder.singleValueContainer().decode(String.self) else {
            self = .item(try MenuBarItemReference(from: decoder))
            return
        }
        guard name == "symbol" else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "Use \"symbol\" or an object that names an app."))
        }
        self = .symbol
    }

    var configurationValue: ConfigurationValue {
        switch self {
        case let .item(reference): reference.configurationValue
        case .symbol: .string("symbol")
        }
    }
}

extension [MenuBarItemsEntry] {
    var references: [MenuBarItemReference] {
        compactMap { entry in
            if case let .item(reference) = entry { return reference }
            return nil
        }
    }
}

enum MenuBarItemPlacement: CaseIterable {
    case bar, row, hidden

    var title: String {
        switch self {
        case .bar: "Bar"
        case .row: "Row"
        case .hidden: "Hidden"
        }
    }
}

enum MenuBarItemSource {
    case item(MenuBarItem)
    case shown(Int)
    case hidden(Int)

    var placement: MenuBarItemPlacement {
        switch self {
        case .item: .row
        case .shown: .bar
        case .hidden: .hidden
        }
    }
}

func menuBarItemsProperties(shown: [MenuBarItemsEntry], hidden: [MenuBarItemsEntry], moving source: MenuBarItemSource,
                            to placement: MenuBarItemPlacement, before index: Int?, among items: [MenuBarItem]) -> [String: ConfigurationValue] {
    guard placement != source.placement || index != nil else { return [:] }
    var nextShown = shown
    var nextHidden = hidden
    var index = index
    let entry: MenuBarItemsEntry
    switch source {
    case let .item(item):
        let several = items.filter { $0.bundleID == item.bundleID && $0.appName == item.appName }.count > 1
        entry = .item(MenuBarItemReference(app: item.bundleID ?? item.appName, item: several ? item.identifier ?? item.entry.title : nil))
    case let .shown(position):
        entry = nextShown.remove(at: position)
        if placement == .bar, let before = index, before > position { index = before - 1 }
    case let .hidden(position):
        entry = nextHidden.remove(at: position)
        if placement == .hidden, let before = index, before > position { index = before - 1 }
    }
    switch placement {
    case .bar: nextShown.insert(entry, at: index ?? nextShown.count)
    case .hidden: nextHidden.insert(entry, at: index ?? nextHidden.count)
    case .row: break
    }
    var properties: [String: ConfigurationValue] = [:]
    if nextShown != shown { properties["shown"] = .array(nextShown.map(\.configurationValue)) }
    if nextHidden != hidden { properties["hidden"] = .array(nextHidden.map(\.configurationValue)) }
    return properties
}

struct FoundMenuBarItem {
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    let description: String?
    let identifier: String?
    let hasMenu: Bool

    init(_ element: AXUIElement, pid: pid_t, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) {
        AXUIElementSetMessagingTimeout(element, 0.1)
        self.pid = pid
        self.element = element
        frame = StableBar.frame(of: element, readAttribute)
        description = readAttribute(kAXDescriptionAttribute, element) as? String
        identifier = readAttribute(kAXIdentifierAttribute, element) as? String
        let children = readAttribute(kAXChildrenAttribute, element) as? [AXUIElement] ?? []
        let menu = children.first { child in
            AXUIElementSetMessagingTimeout(child, 0.1)
            return readAttribute(kAXRoleAttribute, child) as? String == kAXMenuRole
        }
        let rows = menu.flatMap { readAttribute(kAXChildrenAttribute, $0) as? [AXUIElement] } ?? []
        // StableBar can't draw a row with neither a title nor text, such as a row of buttons, so its menu opens as the app's own.
        hasMenu = !children.isEmpty && rows.allSatisfy { row in
            AXUIElementSetMessagingTimeout(row, 0.1)
            return (readAttribute(kAXTitleAttribute, row) as? String ?? text(in: row, readAttribute)) != nil
        }
    }
}

let menuBarAgentID = "com.apple.MenuBarAgent"

/// The items in the macOS menu bar. Up to macOS 26, each app lists its own in its extras menu bar. From macOS 27 on,
/// MenuBarAgent draws them all, and when its windows hold none, as on systems without it, the apps' lists are read instead.
func foundMenuBarItems(apps: [pid_t], agent: pid_t?,
                       readAttribute: @escaping @Sendable (String, AXUIElement) -> CFTypeRef?) async -> [FoundMenuBarItem] {
    if let agent {
        let items = await menuBarAgentItems(agent: agent, readAttribute: readAttribute)
        if !items.isEmpty { return items }
    }
    return await withTaskGroup { group in
        for pid in apps {
            group.addTask {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.1)
                let children = readAttribute(kAXExtrasMenuBarAttribute, app).flatMap {
                    readAttribute(kAXChildrenAttribute, $0 as! AXUIElement) as? [AXUIElement]
                } ?? []
                return children.map { FoundMenuBarItem(menuBarExtra($0, readAttribute), pid: pid, readAttribute) }
            }
        }
        var items: [FoundMenuBarItem] = []
        for await found in group { items += found }
        return items
    }
}

/// An item of an extras menu bar. From macOS 27 on, MenuBarAgent lists macOS's own items there, each in a hosting view.
func menuBarExtra(_ element: AXUIElement, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) -> AXUIElement {
    AXUIElementSetMessagingTimeout(element, 0.1)
    guard readAttribute(kAXRoleAttribute, element) as? String == kAXGroupRole else { return element }
    return (readAttribute(kAXChildrenAttribute, element) as? [AXUIElement])?.first ?? element
}

/// The items in the menu bar that MenuBarAgent draws from macOS 27 on, where apps no longer list their own. It keeps one
/// window per display, and only the active display's window holds the items themselves; the others hold their apps, which
/// can't be pressed. So the window with the most items is the one to read.
func menuBarAgentItems(agent: pid_t, readAttribute: @escaping @Sendable (String, AXUIElement) -> CFTypeRef?) async -> [FoundMenuBarItem] {
    let app = AXUIElementCreateApplication(agent)
    AXUIElementSetMessagingTimeout(app, 0.1)
    let windows = (readAttribute(kAXWindowsAttribute, app) as? [AXUIElement] ?? []).map {
        readAttribute(kAXChildrenAttribute, $0) as? [AXUIElement] ?? []
    }
    let found = await withTaskGroup { group in
        for (window, slots) in windows.enumerated() {
            for slot in slots {
                group.addTask { menuBarAgentItem(in: slot, agent: agent, readAttribute).map { (window, $0) } }
            }
        }
        var found: [(window: Int, item: FoundMenuBarItem)] = []
        for await item in group { if let item { found.append(item) } }
        return found
    }
    let counts = windows.indices.map { window in found.count { $0.window == window } }
    guard let window = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return [] }
    return found.filter { $0.window == window }.map(\.item)
}

/// The item in one of MenuBarAgent's slots: one of macOS's own items inside its hosting view, or another app's button.
/// Time Machine's item, which SystemUIServer draws, reports its role as unknown.
private func menuBarAgentItem(in slot: AXUIElement, agent: pid_t, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) -> FoundMenuBarItem? {
    AXUIElementSetMessagingTimeout(slot, 0.1)
    guard let child = (readAttribute(kAXChildrenAttribute, slot) as? [AXUIElement])?.first else { return nil }
    let element = menuBarExtra(child, readAttribute)
    switch readAttribute(kAXRoleAttribute, element) as? String {
    case kAXMenuBarItemRole:
        return FoundMenuBarItem(element, pid: agent, readAttribute)
    case kAXButtonRole, kAXUnknownRole:
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return FoundMenuBarItem(element, pid: pid, readAttribute)
    default:
        return nil
    }
}

/// The app a menu bar item belongs to. MenuBarAgent draws macOS's own items, which Control Center drew before macOS 27,
/// so they stay under Control Center, as the configuration names them.
/// `runningApplications` can list the same PID twice.
func runningAppsByPID(_ apps: [NSRunningApplication], leavingOut ownPID: pid_t) -> [pid_t: NSRunningApplication] {
    Dictionary(apps.filter { $0.processIdentifier != ownPID }.map { ($0.processIdentifier, $0) }) { first, _ in first }
}

func menuBarItemApp(pid: pid_t, in apps: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
    guard let app = apps[pid] else { return nil }
    guard app.bundleIdentifier == menuBarAgentID else { return app }
    return apps.values.first { $0.bundleIdentifier == "com.apple.controlcenter" } ?? app
}

/// Symbols for macOS's own menu bar items, by the item's Accessibility identifier, or by its app's bundle ID when the item has
/// none. Control Center, SystemUIServer and TextInputMenuAgent draw these items, so their apps' icons don't tell them apart.
/// From macOS 27 on, Siri (`com.apple.campo`) draws Search.
let menuBarSymbols = [
    "com.apple.menuextra.accessibility-shortcuts": "accessibility", "com.apple.menuextra.airdrop": "dot.radiowaves.up.forward",
    "com.apple.menuextra.airplay": "airplayvideo", "com.apple.menuextra.airport": "wifi", "com.apple.menuextra.appleuser": "person.crop.circle",
    "com.apple.menuextra.battery": "battery.100percent", "com.apple.menuextra.clock": "clock", "com.apple.menuextra.controlcenter": "switch.2",
    "com.apple.menuextra.display": "sun.max.fill", "com.apple.menuextra.eject": "eject.fill", "com.apple.menuextra.faceTime": "video.fill",
    "com.apple.menuextra.focusmode": "moon.fill", "com.apple.menuextra.hearing": "ear", "com.apple.menuextra.keyboard-brightness": "light.max",
    "com.apple.menuextra.musicrecognition": "shazam.logo", "com.apple.menuextra.now-playing": "play.fill",
    "com.apple.menuextra.screen-mirroring": "rectangle.on.rectangle", "com.apple.menuextra.shortcuts": "square.2.layers.3d",
    "com.apple.menuextra.sound": "speaker.wave.2.fill", "com.apple.menuextra.stagemanager": "squares.leading.rectangle",
    "com.apple.menuextra.textinput": "keyboard", "com.apple.menuextra.TimeMachine": "clock.arrow.circlepath", "com.apple.menuextra.timer": "timer",
    "com.apple.menuextra.universalaccess": "accessibility", "com.apple.menuextra.volume": "speaker.wave.2.fill",
    "com.apple.menuextra.vpn": "network.badge.shield.half.filled", "com.apple.menuextra.wifi": "wifi",
    "com.apple.menuextra.wwan": "antenna.radiowaves.left.and.right", "com.apple.Spotlight": "magnifyingglass",
    "com.apple.campo": "magnifyingglass", "com.apple.TextInputMenuAgent": "keyboard",
]

/// The actions whose default icon macOS 27 still shows in menus; it hides the others. `NSMenuItem` gives each its icon.
let shownMenuActions: Set<String> = [
    "print:", "printDocument:", "runPageLayout:", "showHelp:", "startDictation:", "orderFrontCharacterPalette:", "orderFrontFontPanel:",
    "orderFrontColorPanel:", "orderFrontPreferencesPanel:", "orderFrontListPanel:", "orderFrontTablePanel:", "alignLeft:", "alignCenter:",
    "alignRight:", "alignJustified:", "_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:",
    "_handleInsertFromCreditCardsCommand:", "_openFeedbackAssistant:", "_searchWithGoogleFromMenu:",
]

/// The symbols macOS 27 shows on the items it adds to apps' menus, by identifier: the Apple menu, the Window menu's
/// tiling, display and window items, and Edit's AutoFill.
let systemMenuSymbols: [String: String] = {
    var symbols = [
        "_systemSettingsRequested:": "gear", "_appStoreRequested:": "appstore", "_NSMenuItemAutoFillIdentifier": "rectangle.and.pencil.and.ellipsis",
        "_zoomLeft:": "inset.filled.lefthalf.rectangle", "_zoomRight:": "inset.filled.righthalf.rectangle",
        "_zoomTop:": "inset.filled.tophalf.rectangle", "_zoomBottom:": "inset.filled.bottomhalf.rectangle",
        "_zoomTopLeft:": "inset.filled.topleft.rectangle", "_zoomTopRight:": "inset.filled.topright.rectangle",
        "_zoomBottomLeft:": "inset.filled.bottomleft.rectangle", "_zoomBottomRight:": "inset.filled.bottomright.rectangle",
        "_zoomLeftAndRight:": "inset.filled.lefthalf.righthalf.rectangle", "_zoomRightAndLeft:": "inset.filled.righthalf.lefthalf.rectangle",
        "_zoomLeftThreeUp:": "inset.filled.lefthalf.topright.bottomright.rectangle",
        "_zoomRightThreeUp:": "inset.filled.topleft.bottomleft.righthalf.rectangle",
        "_zoomTopAndBottom:": "inset.filled.tophalf.bottomhalf.rectangle", "_zoomBottomAndTop:": "inset.filled.bottomhalf.tophalf.rectangle",
        "_zoomTopThreeUp:": "inset.filled.tophalf.bottomleft.bottomright.rectangle",
        "_zoomBottomThreeUp:": "inset.filled.topleft.topright.bottomhalf.rectangle",
        "_zoomQuarters:": "inset.filled.topleft.topright.bottomleft.bottomright.rectangle",
        "_tileLeft:": "inset.filled.lefthalf.rectangle", "_tileRight:": "inset.filled.righthalf.rectangle",
        "_moveToDisplay:": "display", "_moveAllToDisplay:": "display", "makeKeyAndOrderFront:": "interface.window",
    ]
    if let mac = macSymbol() {
        symbols["_aboutThisMacRequested:"] = mac
        symbols["_systemInformationRequested:"] = mac
    }
    return symbols
}()

/// The symbols of Move & Resize and Full Screen Tile, by the first action in their submenu.
let windowSubmenuSymbols = ["_zoomLeft:": "inset.filled.trailinghalf.arrowtriangle.forward.rectangle", "_tileLeft:": "rectangle.split.2x1"]

/// The icon macOS 27 shows beside a menu item with the Accessibility identifier `identifier`, or `nil` when it shows none.
@MainActor func appMenuIcon(identifier: String) -> NSImage? {
    if let symbol = systemMenuSymbols[identifier] {
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? PrivateAPI.privateSymbol(symbol)
    }
    return shownMenuActions.contains(identifier) ? NSMenuItem(title: "", action: NSSelectorFromString(identifier), keyEquivalent: "").image : nil
}

/// The symbol macOS draws for this Mac, such as `macbook.gen2`: the one declared by the first type with a symbol on the way
/// from its model's type through each type's first parent. A MacBook Pro conforms to both notched and notchless laptops
/// through different parents, so the first parent decides. `UTTypeCopyDeclaration` leaves symbols out, so they come
/// from CoreTypes, which declares the families of Macs that have one.
private func macSymbol() -> String? {
    let declarations = Bundle(path: "/System/Library/CoreServices/CoreTypes.bundle")?.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]]
    var symbols: [String: String] = [:]
    for declaration in declarations ?? [] {
        if let identifier = declaration["UTTypeIdentifier"] as? String,
           let symbol = (declaration["UTTypeIcons"] as? [String: Any])?["UTTypeSymbolName"] as? String { symbols[identifier] = symbol }
    }
    var identifier = UTType(tag: MacFacts.sysctl("hw.model"), tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)?.identifier
    while let type = identifier {
        if let symbol = symbols[type] { return symbol }
        let parents = (UTTypeCopyDeclaration(type as CFString)?.takeRetainedValue() as? [String: Any])?["UTTypeConformsTo"]
        identifier = parents as? String ?? (parents as? [String])?.first
    }
    return nil
}

/// The icon the Menu bar items row shows: a symbol for macOS's own items, otherwise the icon of the app the item's process
/// belongs to. A process without an icon of its own, such as a system agent, gets a menu bar symbol instead of macOS's
/// blank app icon.
func menuBarIcon(identifier: String?, app: NSRunningApplication) -> NSImage {
    let key = identifier ?? app.bundleIdentifier ?? ""
    if key == "com.apple.menuextra.bluetooth" { return bluetoothGlyph() }
    if let symbol = menuBarSymbols[key].flatMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) { return symbol }
    guard let bundle = iconBundle(containing: app.bundleURL) else {
        return NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)!
    }
    return retinaArt(of: NSWorkspace.shared.icon(forFile: bundle.path))
}

/// The app whose icon stands for a process at `url`: its own bundle when that declares an icon, otherwise the nearest app
/// around it that does, as for a helper or daemon inside an app. `nil` when there is none, as for the system agent behind
/// the input menu.
func iconBundle(containing url: URL?) -> URL? {
    var url = url?.standardizedFileURL
    while let current = url, current.pathComponents.count > 1 {
        if current.pathExtension == "app", let info = Bundle(url: current)?.infoDictionary,
           ["CFBundleIconFile", "CFBundleIconName", "CFBundleIcons"].contains(where: { info[$0] != nil }) { return current }
        url = current.deletingLastPathComponent()
    }
    return nil
}

/// `icon` at the row's 18 points, always from its Retina art, which a 1× display scales down. Some apps ship broken 1×
/// images: Docker Desktop's 16, 32 and 48 px ones are noise, and a 1× display would otherwise draw one of them.
func retinaArt(of icon: NSImage) -> NSImage {
    var rect = CGRect(x: 0, y: 0, width: 18, height: 18)
    let retina = NSAffineTransform()
    retina.scale(by: 2)
    guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: retina]) else { return icon }
    return NSImage(cgImage: image, size: rect.size)
}

/// The Bluetooth rune, which SF Symbols doesn't include, drawn as a template image like a symbol.
private func bluetoothGlyph() -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 18), flipped: true) { _ in
        let rune = NSBezierPath()
        rune.move(to: NSPoint(x: 2, y: 5.5))
        rune.line(to: NSPoint(x: 10, y: 12.5))
        rune.line(to: NSPoint(x: 6, y: 16.25))
        rune.line(to: NSPoint(x: 6, y: 1.75))
        rune.line(to: NSPoint(x: 10, y: 5.5))
        rune.line(to: NSPoint(x: 2, y: 12.5))
        rune.lineWidth = 1.6
        rune.lineCapStyle = .round
        rune.lineJoinStyle = .round
        NSColor.black.setStroke()
        rune.stroke()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Bluetooth"
    return image
}

/// The values of `names` on `element` from one Accessibility call, nil where the element has no value. The element's
/// messaging timeout applies.
func copyAttributes(_ names: [String], of element: AXUIElement) -> [CFTypeRef?] {
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
          let values = values as? [AnyObject], values.count == names.count else { return names.map { _ in nil } }
    return values.map { value in
        let type = CFGetTypeID(value)
        if type == CFNullGetTypeID() { return nil }
        if type == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }
}

func frame(of element: AXUIElement, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) -> CGRect {
    var position = CGPoint.zero
    var size = CGSize.zero
    if let value = readAttribute(kAXPositionAttribute, element) { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
    if let value = readAttribute(kAXSizeAttribute, element) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: position, size: size)
}

/// The text a menu item draws in its child views, as CodexBar's and Tailscale's do, without its submenu's.
private func text(in element: AXUIElement, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) -> String? {
    let parts = (readAttribute(kAXChildrenAttribute, element) as? [AXUIElement] ?? []).compactMap { child -> String? in
        AXUIElementSetMessagingTimeout(child, 0.1)
        switch readAttribute(kAXRoleAttribute, child) as? String {
        case kAXStaticTextRole: return readAttribute(kAXValueAttribute, child) as? String
        case kAXMenuRole: return nil
        default: return text(in: child, readAttribute)
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

private func showsPanel(_ pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
    return windows.contains {
        $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as! Int > 0
            && CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)!.height > 100
    }
}

private func menuBarDisplay(of frame: CGRect) -> CGDirectDisplayID? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &displays, &count)
    return displays.prefix(Int(count)).first {
        let bounds = CGDisplayBounds($0)
        return bounds.minX <= frame.midX && frame.midX < bounds.maxX && abs(frame.midY - bounds.minY) < frame.height * 2
    }
}

/// A menu item's shortcut as Accessibility reports it. Accessibility doesn't expose `isAlternate`, and every item reports
/// itself as its `AXMenuItemPrimaryUIElement`, so an alternate can only be told by its shortcut.
private struct MenuItemKey {
    let character: String?
    let virtualKey: Int?
    let glyph: Int?
    let modifiers: Int

    /// Whether this item has the same key as `item` and adds exactly Option, as AppKit's alternates do. Command doesn't
    /// count: an alternate without a key reports none. Shift doesn't make an alternate: Redo follows Undo.
    func isAlternate(of item: MenuItemKey) -> Bool {
        let option = MenuShortcut.Modifier.option
        let held = MenuShortcut.Modifier.shift | option | MenuShortcut.Modifier.control
        return character == item.character && virtualKey == item.virtualKey && glyph == item.glyph
            && item.modifiers & option == 0 && modifiers & held == item.modifiers & held | option
    }
}
