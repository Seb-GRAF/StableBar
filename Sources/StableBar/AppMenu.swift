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
    var symbol: String? = nil
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
                                        hasSubmenu: submenu(of: child) != nil,
                                        symbol: title.isEmpty ? nil : symbol(for: title, of: child)))
        }
        if entries.last?.title.isEmpty == true { entries.removeLast() }
        return entries
    }

    /// Accessibility doesn't share menu item images, so standard commands get the symbols macOS 26 gives their actions, found by title or shortcut.
    /// Earlier versions draw menus without them.
    private func symbol(for title: String, of item: AXUIElement) -> String? {
        guard #available(macOS 26, *) else { return nil }
        if let symbol = menuItemSymbol(title: title) { return symbol }
        guard let key = attribute(kAXMenuItemCmdCharAttribute, of: item) as? String else { return nil }
        return menuShortcutSymbols[MenuShortcut(key: key, modifiers: attribute(kAXMenuItemCmdModifiersAttribute, of: item) as? Int ?? 0)]
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

    func menuBarItemsPopup() async -> PopupConfiguration? {
        guard checkAccess() else {
            requestAccessibility()
            return nil
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
        let entries = items.sorted { $0.frame.midX < $1.frame.midX }.compactMap { item in
            menuBarDisplay(of: item.frame).map { display in
                let app = apps[item.pid]!
                return AppMenuEntry(title: item.description ?? app.localizedName ?? "", element: item.element, isEnabled: true, isChecked: false,
                                    hasSubmenu: item.hasMenu,
                                    icon: menuBarSymbols[item.identifier ?? app.bundleIdentifier ?? ""].map {
                                        NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
                                    } ?? app.icon,
                                    menuBarDisplay: display)
            }
        }
        return PopupConfiguration(style: WidgetStyle(paddingHorizontal: 5, paddingVertical: 5, spacing: 0, width: Double(entries.count * 28 + 10)),
                                  layout: PopupBlock(content: .menuBarItems(entries)))
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

private struct FoundMenuBarItem {
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    let description: String?
    let identifier: String?
    let hasMenu: Bool
}

private let menuBarSymbols = ["com.apple.menuextra.battery": "battery.100percent", "com.apple.menuextra.clock": "clock",
                              "com.apple.menuextra.controlcenter": "switch.2", "com.apple.Spotlight": "magnifyingglass"]

// The symbols AppKit gives standard menu actions on macOS 26, with public stand-ins for its private Help and Emoji & Symbols ones.
// Names with an underscore are AppKit's own images, not SF Symbols.
let menuTitleSymbols = [
    "Settings…": "gear", "Preferences…": "gear", "Hide Others": "Hide_others", "Show All": "macwindow.on.rectangle", "Quit": "Quit_app",
    "New": "plus", "Open…": "arrow.up.forward", "Close": "xmark", "Close Window": "xmark", "Close Tab": "xmark", "Close All": "xmark.rectangle",
    "Save": "square.and.arrow.down", "Save…": "square.and.arrow.down", "Save As…": "square.and.arrow.down.on.square",
    "Duplicate": "plus.square.on.square", "Rename…": "pencil", "Move To…": "folder", "Revert to Saved": "arrow.counterclockwise",
    "Export as PDF…": "arrow.up.document", "Page Setup…": "text.page", "Print…": "printer",
    "Undo": "arrow.uturn.backward", "Redo": "arrow.uturn.forward", "Cut": "scissors", "Copy": "document.on.document", "Paste": "document.on.clipboard",
    "Paste and Match Style": "Paste_and_Match", "Paste and Retain Style": "Paste_and_Retain", "Delete": "trash", "Select All": "character.textbox",
    "Copy Link": "link", "Start Dictation…": "microphone", "Emoji & Symbols": "face.smiling", "Show Fonts": "textformat",
    "Show Colors": "paintpalette", "Start Speaking": "play", "Stop Speaking": "stop", "Customize Toolbar…": "wrench.adjustable",
    "Show Sidebar": "sidebar.leading", "Hide Sidebar": "sidebar.leading", "Zoom In": "plus.magnifyingglass", "Zoom Out": "minus.magnifyingglass",
    "Minimize": "minus.rectangle", "Minimize All": "minus.rectangle",
    "Zoom": "square.arrowtriangle.4.outward", "Zoom All": "square.arrowtriangle.4.outward",
    "Bring All to Front": "square.3.layers.3d", "Arrange in Front": "square.3.layers.3d", "Merge All Windows": "macwindow.on.rectangle",
    "Move Tab to New Window": "macwindow.badge.plus", "Show Next Tab": "chevron.forward.square", "Show Previous Tab": "chevron.backward.square",
]

let menuTitlePrefixSymbols = ["About ": "info.circle", "Quit ": "Quit_app", "Undo ": "arrow.uturn.backward", "Redo ": "arrow.uturn.forward"]
let menuTitleSuffixSymbols = [" Help": "questionmark.circle"]

func menuItemSymbol(title: String) -> String? {
    let title = title.replacingOccurrences(of: "...", with: "…")
    return menuTitleSymbols[title] ?? menuTitlePrefixSymbols.first { title.hasPrefix($0.key) }?.value
        ?? menuTitleSuffixSymbols.first { title.hasSuffix($0.key) }?.value
}

struct MenuShortcut: Hashable {
    let key: String
    let modifiers: Int

    /// `modifiers` holds the Accessibility menu modifier flags: 0 is ⌘ alone, then 1 adds ⇧, 2 ⌥, 4 ⌃, and 8 removes ⌘.
    init(key: String, modifiers: Int = 0) {
        self.key = key.uppercased()
        self.modifiers = modifiers
    }
}

// Shortcuts that mean the same command in nearly every app, for menus in other languages. ⌘P is left out: some apps use it for Go to File.
let menuShortcutSymbols: [MenuShortcut: String] = [
    MenuShortcut(key: "Q"): "Quit_app", MenuShortcut(key: "H"): "Hide_app",
    MenuShortcut(key: "H", modifiers: 2): "Hide_others", MenuShortcut(key: ","): "gear",
    MenuShortcut(key: "N"): "plus", MenuShortcut(key: "O"): "arrow.up.forward", MenuShortcut(key: "W"): "xmark",
    MenuShortcut(key: "S"): "square.and.arrow.down", MenuShortcut(key: "Z"): "arrow.uturn.backward",
    MenuShortcut(key: "Z", modifiers: 1): "arrow.uturn.forward", MenuShortcut(key: "X"): "scissors",
    MenuShortcut(key: "C"): "document.on.document", MenuShortcut(key: "V"): "document.on.clipboard",
    MenuShortcut(key: "V", modifiers: 3): "Paste_and_Match",
    MenuShortcut(key: "A"): "character.textbox", MenuShortcut(key: "M"): "minus.rectangle",
    MenuShortcut(key: "?"): "questionmark.circle", MenuShortcut(key: "?", modifiers: 1): "questionmark.circle",
]

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
