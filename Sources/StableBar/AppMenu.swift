import AppKit
@preconcurrency import ApplicationServices
import Observation

struct AppMenuItem: Hashable {
    let title: String
    let element: AXUIElement
}

@MainActor @Observable
final class AppMenu: NSObject, NSMenuDelegate {
    private(set) var appleMenu: AppMenuItem?
    private(set) var items: [AppMenuItem] = []
    private(set) var isTrusted: Bool
    @ObservationIgnored private let checkAccess: () -> Bool
    @ObservationIgnored private let readAttribute: (String, AXUIElement) -> CFTypeRef?
    @ObservationIgnored private var app: NSRunningApplication?
    @ObservationIgnored private var menus: [NSMenu: AXUIElement] = [:]
    @ObservationIgnored private var nextTitle: Int?
    @ObservationIgnored private(set) var retryTask: Task<Void, Never>?

    init(checkAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         readAttribute: @escaping (String, AXUIElement) -> CFTypeRef? = { name, element in
             var value: CFTypeRef?
             guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
             return value
         }) {
        self.checkAccess = checkAccess
        self.readAttribute = readAttribute
        isTrusted = checkAccess()
        super.init()
    }

    func read(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier == ProcessInfo.processInfo.processIdentifier || app.bundleIdentifier == "org.stablebar.app" { return }
        retryTask?.cancel()
        retryTask = nil
        self.app = app
        if readItems() { return }
        retryTask = Task { [weak self] in
            do {
                for delay in [250, 500, 1000, 2000] {
                    try await Task.sleep(for: .milliseconds(delay))
                    guard let self else { return }
                    if readItems() { return }
                }
            } catch {}
        }
    }

    private func readItems() -> Bool {
        isTrusted = checkAccess()
        var next: [AppMenuItem] = []
        if isTrusted, let app {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            guard let menuBar = attribute(kAXMenuBarAttribute, of: element),
                  let children = attribute(kAXChildrenAttribute, of: menuBar as! AXUIElement) as? [AXUIElement] else { return false }
            for item in children {
                guard let title = attribute(kAXTitleAttribute, of: item) as? String else { return false }
                next.append(AppMenuItem(title: title, element: item))
            }
        }
        if next.first != appleMenu { appleMenu = next.first }
        if Array(next.dropFirst()) != items { items = Array(next.dropFirst()) }
        return true
    }

    func refresh() {
        read(app)
    }

    func open(_ item: AppMenuItem, at location: NSPoint, in view: NSView?) {
        var pid: pid_t = 0
        AXUIElementGetPid(item.element, &pid)
        guard pid == app?.processIdentifier else { return }
        let menu = NSMenu()
        menu.delegate = self
        menus = [menu: item.element]
        menu.popUp(positioning: nil, at: location, in: view)
        menus = [:]
    }

    func open(_ index: Int, of items: [AppMenuItem], at anchors: [NSView], opened: (Int) -> Void) {
        let window = anchors[index].window!
        let frames = anchors.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
        let top = popupAttachmentTop(anchor: frames[index], window: window.frame, geometry: (window as? BarPanel)?.barGeometry)
        nextTitle = index
        while let index = nextTitle {
            nextTitle = nil
            opened(index)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let title = frames.firstIndex(where: { $0.contains(NSEvent.mouseLocation) }), title != index else { return }
                    self.nextTitle = title
                    for menu in self.menus.keys { menu.cancelTrackingWithoutAnimation() }
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            open(items[index], at: anchors[index].convert(window.convertPoint(fromScreen: NSPoint(x: frames[index].minX, y: top)), from: nil),
                 in: anchors[index])
            timer.invalidate()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let element = menus[menu], let source = children(of: element).first else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false
        for child in children(of: source) {
            guard let title = attribute(kAXTitleAttribute, of: child) as? String, !title.isEmpty else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(press), keyEquivalent: "")
            item.target = self
            item.representedObject = child
            item.isEnabled = attribute(kAXEnabledAttribute, of: child) as? Bool == true
            item.state = attribute(kAXMenuItemMarkCharAttribute, of: child) as? String == nil ? .off : .on
            if !children(of: child).isEmpty {
                let submenu = NSMenu()
                submenu.delegate = self
                menus[submenu] = child
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    @objc private func press(_ sender: NSMenuItem) {
        let element = sender.representedObject as! AXUIElement
        Task.detached { AXUIElementPerformAction(element, kAXPressAction as CFString) }
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        readAttribute(name, element)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }
}
