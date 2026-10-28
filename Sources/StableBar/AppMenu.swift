import AppKit
@preconcurrency import ApplicationServices
import Observation
import SwiftUI

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
    var icon: NSImage? = nil
    var menuBarDisplay: CGDirectDisplayID? = nil
}

@MainActor @Observable
final class AppMenu: NSObject {
    private(set) var appleMenu: AppMenuItem?
    private(set) var items: [AppMenuItem] = []
    private(set) var isTrusted: Bool
    @ObservationIgnored private let checkAccess: () -> Bool
    @ObservationIgnored private let readAttribute: @Sendable (String, AXUIElement) -> CFTypeRef?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var app: NSRunningApplication?
    @ObservationIgnored private var submenus: [PopupPanel] = []
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    @ObservationIgnored private var menuBarPresses = 0
    private(set) var menuBarItems: [MenuBarItem] = []
    @ObservationIgnored var hidesMenuBar = false {
        didSet { if hidesMenuBar != oldValue { setMenuBarHidden(hidesMenuBar) } }
    }

    init(checkAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         readAttribute: @escaping @Sendable (String, AXUIElement) -> CFTypeRef? = { name, element in
             var value: CFTypeRef?
             guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
             return value
         },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.checkAccess = checkAccess
        self.readAttribute = readAttribute
        self.sleep = sleep
        isTrusted = checkAccess()
        super.init()
    }

    func read(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier == ProcessInfo.processInfo.processIdentifier || app.bundleIdentifier == "org.stablebar.app" { return }
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
        var pid: pid_t = 0
        AXUIElementGetPid(item.element, &pid)
        guard pid == app?.processIdentifier else { return nil }
        return popup(entries(of: item.element))
    }

    private func popup(_ entries: [AppMenuEntry]) -> PopupConfiguration {
        var popup = PopupConfiguration(style: WidgetStyle(paddingHorizontal: 5, paddingVertical: 5, spacing: 0, width: 260),
                                       layout: PopupBlock(content: .appMenu(entries)))
        popup.alignment = .leading
        return popup
    }

    private func entries(of element: AXUIElement) -> [AppMenuEntry] {
        guard let menu = submenu(of: element) else { return [] }
        var entries: [AppMenuEntry] = []
        for child in children(of: menu) {
            guard let title = attribute(kAXTitleAttribute, of: child) as? String ?? text(in: child),
                  !title.isEmpty || entries.last?.title.isEmpty == false else { continue }
            entries.append(AppMenuEntry(title: title, element: child,
                                        isEnabled: attribute(kAXEnabledAttribute, of: child) as? Bool == true,
                                        isChecked: attribute(kAXMenuItemMarkCharAttribute, of: child) as? String != nil,
                                        hasSubmenu: submenu(of: child) != nil))
        }
        if entries.last?.title.isEmpty == true { entries.removeLast() }
        return entries
    }

    private func submenu(of element: AXUIElement) -> AXUIElement? {
        children(of: element).first { attribute(kAXRoleAttribute, of: $0) as? String == kAXMenuRole }
    }

    private func text(in element: AXUIElement) -> String? {
        let parts = children(of: element).compactMap { child in
            attribute(kAXRoleAttribute, of: child) as? String == kAXStaticTextRole ? attribute(kAXValueAttribute, of: child) as? String : text(in: child)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func openSubmenu<Content: View>(_ element: AXUIElement?, beside row: NSView, content: (PopupConfiguration) -> Content) {
        let window = row.window!
        closeSubmenus(after: window)
        guard let element else { return }
        let popup = popup(entries(of: element))
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
              !showsPanel(app.processIdentifier),
              let menuBar = attribute(kAXExtrasMenuBarAttribute, of: AXUIElementCreateApplication(app.processIdentifier)),
              let item = children(of: menuBar as! AXUIElement).first(where: {
                  attribute(kAXIdentifierAttribute, of: $0) as? String == "com.apple.menuextra.controlcenter"
              }),
              let display = menuBarDisplay(of: frame(of: item, readAttribute)) else { return }
        pressInMenuBar(item, on: display)
    }

    func popup(forMenuBarItem element: AXUIElement) -> PopupConfiguration {
        popup(entries(of: element))
    }

    func readMenuBarItems(requestingAccess: Bool) async -> Bool {
        guard checkAccess() else {
            if requestingAccess { requestAccessibility() }
            return false
        }
        let apps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { ($0.processIdentifier, $0) })
        let readAttribute = readAttribute
        let items = await withTaskGroup { group in
            for pid in apps.keys {
                group.addTask {
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, 0.1)
                    let children = readAttribute(kAXExtrasMenuBarAttribute, app).flatMap {
                        readAttribute(kAXChildrenAttribute, $0 as! AXUIElement) as? [AXUIElement]
                    } ?? []
                    return children.map { item in
                        AXUIElementSetMessagingTimeout(item, 0.1)
                        return FoundMenuBarItem(pid: pid, element: item, frame: frame(of: item, readAttribute),
                                                description: readAttribute(kAXDescriptionAttribute, item) as? String,
                                                identifier: readAttribute(kAXIdentifierAttribute, item) as? String,
                                                hasMenu: (readAttribute(kAXChildrenAttribute, item) as? [AXUIElement])?.isEmpty == false)
                    }
                }
            }
            var items: [FoundMenuBarItem] = []
            for await found in group { items += found }
            return items
        }
        menuBarItems = items.sorted { $0.frame.midX < $1.frame.midX }.compactMap { item in
            menuBarDisplay(of: item.frame).map { display in
                let app = apps[item.pid]!
                return MenuBarItem(entry: AppMenuEntry(title: item.description ?? app.localizedName ?? "", element: item.element, isEnabled: true,
                                                       isChecked: false, hasSubmenu: item.hasMenu, icon: menuBarIcon(identifier: item.identifier, app: app),
                                                       menuBarDisplay: display),
                                   bundleID: app.bundleIdentifier, appName: app.localizedName ?? "", identifier: item.identifier)
            }
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

    private func pressInMenuBar(_ item: AXUIElement, on display: CGDirectDisplayID) {
        let top = CGDisplayBounds(display).minY
        let readAttribute = readAttribute, sleep = sleep
        Task {
            if await Task.detached(operation: { frame(of: item, readAttribute).minY >= top }).value {
                Task.detached { AXUIElementPerformAction(item, kAXPressAction as CFString) }
                return
            }
            menuBarPresses += 1
            let press = menuBarPresses
            setMenuBarHidden(true)
            setMenuBarShown(true, on: display)
            await Task.detached {
                for _ in 0..<25 {
                    if frame(of: item, readAttribute).minY >= top { break }
                    try? await sleep(.milliseconds(20))
                }
                AXUIElementPerformAction(item, kAXPressAction as CFString)
            }.value
            setMenuBarShown(false, on: display)
            await Task.detached {
                while true {
                    let itemFrame = frame(of: item, readAttribute)
                    if itemFrame.height == 0 || itemFrame.maxY <= top { break }
                    try? await sleep(.milliseconds(100))
                }
            }.value
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
}

struct MenuBarItem {
    let entry: AppMenuEntry
    let bundleID: String?
    let appName: String
    let identifier: String?
}

struct MenuBarItemReference: Decodable, Equatable, Sendable {
    let app: String
    var item: String?
    var icon: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case app, item, icon }

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
    }

    func matches(_ item: MenuBarItem) -> Bool {
        (app == item.bundleID || app == item.appName) && (self.item == nil || self.item == item.identifier || self.item == item.entry.title)
    }

    var configurationValue: ConfigurationValue {
        var value: [String: ConfigurationValue] = ["app": .string(app)]
        if let item { value["item"] = .string(item) }
        if let icon { value["icon"] = .string(icon) }
        return .object(value)
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

extension [MenuBarItem] {
    func shown(by shown: [MenuBarItemReference]) -> [(item: MenuBarItem, reference: Int)] {
        shown.indices.flatMap { index in filter(shown[index].matches).map { ($0, index) } }
    }
}

func menuBarItemPlacement(of item: MenuBarItem, shown: [MenuBarItemReference], hidden: [MenuBarItemReference]) -> MenuBarItemPlacement {
    shown.contains { $0.matches(item) } ? .bar : hidden.contains { $0.matches(item) } ? .hidden : .row
}

func menuBarItemsProperties(shown: [MenuBarItemReference], hidden: [MenuBarItemReference], placing item: MenuBarItem,
                            in placement: MenuBarItemPlacement, among items: [MenuBarItem]) -> [String: ConfigurationValue] {
    guard placement != menuBarItemPlacement(of: item, shown: shown, hidden: hidden) else { return [:] }
    var nextShown = shown.filter { !$0.matches(item) }
    var nextHidden = hidden.filter { !$0.matches(item) }
    let several = items.filter { $0.bundleID == item.bundleID && $0.appName == item.appName }.count > 1
    let reference = MenuBarItemReference(app: item.bundleID ?? item.appName, item: several ? item.identifier ?? item.entry.title : nil)
    switch placement {
    case .bar: nextShown.append(reference)
    case .hidden: nextHidden.append(reference)
    case .row: break
    }
    var properties: [String: ConfigurationValue] = [:]
    if nextShown != shown { properties["shown"] = .array(nextShown.map(\.configurationValue)) }
    if nextHidden != hidden { properties["hidden"] = .array(nextHidden.map(\.configurationValue)) }
    return properties
}

private struct FoundMenuBarItem {
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    let description: String?
    let identifier: String?
    let hasMenu: Bool
}

/// Symbols for macOS's own menu bar items, by the item's Accessibility identifier, or by its app's bundle ID when the item has
/// none. Control Center, SystemUIServer and TextInputMenuAgent draw these items, so their apps' icons don't tell them apart.
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
    "com.apple.TextInputMenuAgent": "keyboard",
]

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

private func frame(of element: AXUIElement, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) -> CGRect {
    var position = CGPoint.zero
    var size = CGSize.zero
    if let value = readAttribute(kAXPositionAttribute, element) { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
    if let value = readAttribute(kAXSizeAttribute, element) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: position, size: size)
}

private func showsPanel(_ pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
    return windows.contains {
        $0[kCGWindowOwnerPID as String] as? pid_t == pid && CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)!.height > 100
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
