import AppKit
import SwiftUI

@main
struct StableBarApp {
    @MainActor static func main() {
        do {
            switch try LaunchCommand(arguments: Array(CommandLine.arguments.dropFirst())) {
            case let .trigger(event, environment):
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(event), object: nil, userInfo: environment, deliverImmediately: true)
            case .reload:
                DistributedNotificationCenter.default().postNotificationName(
                    LaunchCommand.reloadNotification, object: nil, userInfo: nil, deliverImmediately: true)
            case let .validate(url):
                var loader = ConfigurationLoader()
                let configuration = try loader.load(url)
                print("Valid configuration: \(configuration.widgets.count) widgets in \(loader.dependencies.count) files.")
            case let .control(url, request):
                let result = try RuntimeControl.send(request, url: url)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            case let .packages(url, action, source):
                let packages = WidgetPackageStore(directory: url.deletingLastPathComponent().appending(path: "packages"))
                if action == "list" {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(packages.list()), as: UTF8.self))
                } else {
                    try printReview(action == "install" ? packages.install(source!) : packages.inspect(source!))
                }
            case let .installFromStore(url, id):
                let packages = WidgetPackageStore(directory: url.deletingLastPathComponent().appending(path: "packages"))
                Task {
                    do {
                        let index = try await PackageIndex.load(from: PackageIndex.url)
                        guard let entry = index.packages.first(where: { $0.id == id }) else { throw WidgetPackageError.notInStore(id) }
                        try printReview(packages.install(await packages.download(entry, from: PackageIndex.url)))
                    } catch {
                        FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
                        exit(1)
                    }
                    exit(0)
                }
                dispatchMain()
            case let .renderDocsImages(directory):
                NSApplication.shared.setActivationPolicy(.accessory)
                Task {
                    do {
                        try await DocsImages.render(to: directory)
                    } catch {
                        FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
                        exit(1)
                    }
                    exit(0)
                }
                NSApplication.shared.run()
            case .help:
                print(LaunchCommand.usage)
            case let .run(url):
                let app = NSApplication.shared
                let delegate = AppDelegate(configurationURL: url)
                app.delegate = delegate
                app.setActivationPolicy(.accessory)
                withExtendedLifetime(delegate) { app.run() }
            }
        } catch {
            FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
            exit(1)
        }
    }

    private static func printReview(_ inspection: WidgetPackageInspection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(inspection.manifest), as: UTF8.self))
        let missing = inspection.manifest.missingTools(path: shellEnvironment.withLock { $0["PATH", default: ""] })
        if !missing.isEmpty { print("Not found on PATH: \(missing.joined(separator: ", "))") }
        switch inspection.manifest.kind {
        case .theme?: break
        case .widgets?: print("This package contains no commands.")
        case nil:
            print("Commands to review before enabling:")
            for command in inspection.commands { print(command) }
        }
    }
}

@MainActor
class BarPanel: NSPanel {
    var barGeometry: BarGeometry?
    var isEditingBar = false {
        didSet {
            guard oldValue, !isEditingBar, isKeyWindow else { return }
            // Ordering out releases a nonactivating panel's keyboard grab and restores
            // the previous app's focus. Ordering front again does not make it key.
            let wasVisible = isVisible
            orderOut(nil)
            if wasVisible { orderFrontRegardless() }
        }
    }
    private(set) var decorationPanel: PassiveBarPanel?

    var drawingFrame: CGRect {
        guard barGeometry?.outsideExtent ?? 0 > 0 else { return frame }
        let height = barGeometry?.panelHeight ?? frame.height
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    override var canBecomeKey: Bool { isEditingBar }
    override var canBecomeMain: Bool { false }
    @objc var hasKeyAppearance: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Decorations live in a separate native window that always ignores mouse events. The
    /// original bar panel keeps its strip-sized hit bounds and its existing background menu.
    func setDecorations(_ content: AnyView?) {
        guard let content else {
            if let decorationPanel { removeChildWindow(decorationPanel); decorationPanel.close() }
            decorationPanel = nil
            return
        }
        let panel: PassiveBarPanel
        if let existing = decorationPanel {
            panel = existing
            (panel.contentView as? NSHostingView<AnyView>)?.rootView = content
        } else {
            panel = PassiveBarPanel(contentRect: drawingFrame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            panel.setAccessibilityElement(false)
            panel.level = level
            panel.collectionBehavior = collectionBehavior
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.setAccessibilityElement(false)
            panel.contentView = host
            decorationPanel = panel
        }
        if panel.frame != drawingFrame { panel.setFrame(drawingFrame, display: false) }
        if isVisible && panel.parent !== self { addChildWindow(panel, ordered: .above) }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        if let decorationPanel, decorationPanel.parent !== self { addChildWindow(decorationPanel, ordered: .above) }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if let decorationPanel, decorationPanel.frame != drawingFrame { decorationPanel.setFrame(drawingFrame, display: flag) }
    }

    override func close() {
        setDecorations(nil)
        super.close()
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: BarStore
    private let setup = SetupWindow()
    private let customization = CustomizationWindow()
    private let themeTrial = ThemeTrialPanel()
    private let editingControls = BarEditControls()
    private let editingKeyboard = BarEditingKeyboard()
    private var control: RuntimeControl?
    private var systemContext: SystemContext?
    private var panels: [CGDirectDisplayID: BarPanel] = [:]
    private var statusItem: NSStatusItem!

    convenience init(configurationURL: URL) {
        self.init(store: BarStore(configurationURL: configurationURL))
    }

    init(store: BarStore, panels: [CGDirectDisplayID: BarPanel] = [:]) {
        self.store = store
        self.panels = panels
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "StableBar")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.onConfigurationChange = { [weak self] in self?.updatePanels() }
        store.onCustomize = { [weak self] in self?.showCustomization() }
        store.onCustomizePackages = { [weak self] in
            guard let self else { return }
            customization.show(store: store, section: .packages)
        }
        store.onCustomizeWidget = { [weak self] id in
            guard let self else { return }
            customization.show(store: store, widgetID: id)
        }
        store.onEndThemeTrial = { [weak self] in self?.themeTrial.cancel() }
        store.onTryThemes = { [weak self] displayID in
            let screens = NSScreen.screens
            guard screens.indices.contains(displayID - 1) else { return }
            self?.showThemeTrial(on: screens[displayID - 1])
        }
        do {
            let control = RuntimeControl { [store] in try store.handle($0) }
            try control.start(url: store.sharedConfigurationURL)
            self.control = control
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            let update = AppUpdate()
            do {
                try update.start()
                store.update = update
            } catch {
                FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
            }
        }
        Task {
            try? await loadLoginShellEnvironment()
            store.start(on: ScreenSetup(NSScreen.screens.map(BarDisplay.init)))
            systemContext = SystemContext { [store] in store.refreshContext() }
            systemContext!.start()
            if !UserDefaults.standard.bool(forKey: "setupCompleted") { showSetup() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func screensChanged() {
        store.barEditing.screensChanged()
        themeTrial.cancel()
        store.popup.close()
        store.retainDisplays(Set(NSScreen.screens.map { BarDisplay(screen: $0).id }))
        store.showScreenSetup(ScreenSetup(NSScreen.screens.map(BarDisplay.init)))
        store.refreshContext()
        updatePanels()
        store.workspaceStore.refreshForDisplayChange()
    }

    @objc private func sleeping() {
        store.setSleeping(true)
        store.windowClearance.stop()
    }

    @objc private func woke() {
        store.setSleeping(false)
        screensChanged()
        store.send(.wake)
    }

    func clearanceDisplay(frame: CGRect, visibleFrame: CGRect, display: BarDisplay, desktopTop: CGFloat) -> WindowClearanceDisplay? {
        guard let configuration = store.clearanceConfiguration else { return nil }
        return WindowClearanceDisplay(frame: frame, visibleFrame: visibleFrame, configuration: configuration,
                                      display: display, desktopTop: desktopTop)
    }

    private func updatePanels() {
        if !store.barEditing.isActive { editingControls.close() }
        guard let config = store.configuration else { return }
        let screens = NSScreen.screens
        var clearanceDisplays: [WindowClearanceDisplay] = []
        var visibleFrames: [CGDirectDisplayID: CGRect] = [:]
        let ids = screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            panels.removeValue(forKey: id)
        }
        for (index, screen) in screens.enumerated() {
            let id = ids[index]
            let panel: BarPanel
            if let existing = panels[id] {
                panel = existing
            } else {
                panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
                panel.title = "StableBar"
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.animationBehavior = .none
                panel.autorecalculatesKeyViewLoop = true
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
                panel.contentView = NSHostingView(rootView: BarView(store: store, display: BarDisplay(screen: screen), nativeDecorations: true))
                panels[id] = panel
            }
            let host = panel.contentView as! NSHostingView<BarView>
            host.sizingOptions = []
            host.rootView = BarView(store: store, display: BarDisplay(screen: screen), nativeDecorations: true)
            let top = screen.frame.maxY
            let geometry = store.barEditing.geometry(for: BarDisplay(screen: screen))!
            let wasEditing = panel.isEditingBar
            panel.isEditingBar = store.barEditing.isActive
            if panel.isEditingBar { panel.setDecorations(nil) }
            panel.barGeometry = geometry
            let height = geometry.inputHeight
            let bar = config.onScreen(ScreenKind(BarDisplay(screen: screen))).bar
            let frame = NSRect(x: screen.frame.minX, y: top - bar.offset - height, width: screen.frame.width, height: height)
            if wasEditing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = bar.animation.duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
            panel.orderFrontRegardless()
            visibleFrames[id] = screen.visibleFrame
            if let clearance = clearanceDisplay(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                                      display: BarDisplay(screen: screen), desktopTop: screens[0].frame.maxY) {
                clearanceDisplays.append(clearance)
            }
        }
        editingControls.update(store: store, bars: panels, visibleFrames: visibleFrames)
        store.windowClearance.update(windows: store.clearanceConfiguration?.bar.keepWindowsClear == true,
                                     notifications: store.clearanceConfiguration?.bar.keepNotificationsClear == true,
                                     displays: clearanceDisplays)
        if store.barEditing.isActive {
            if editingKeyboard.start(store: store) {
                let screen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                if let screen {
                    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
                    panels[id]?.makeKeyAndOrderFront(nil)
                    panels[id]?.selectNextKeyView(nil)
                }
            }
        } else { editingKeyboard.stop() }
        themeTrial.reposition()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "StableBar", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        if !panels.isEmpty {
            if store.barEditing.isAvailable { addItem(store.barEditing.menuTitle, action: #selector(editBar), to: menu) }
            addItem("Try Themes…", action: #selector(tryThemes), to: menu)
            menu.addItem(.separator())
        }
        addItem("Getting Started…", action: #selector(showSetup), to: menu)
        addItem("User Guide", action: #selector(showUserGuide), to: menu)
        if let update = store.update {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdate.checkForUpdates), keyEquivalent: "").target = update
        }
        if let error = store.configurationError ?? store.workspaceStore.error {
            menu.addItem(.separator())
            menu.addItem(withTitle: error, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        addItem("Settings…", action: #selector(showCustomization), to: menu)
        addItem("Quit StableBar", action: #selector(quit), to: menu)
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func showCustomization() { customization.show(store: store) }
    @objc private func editBar() { store.barEditing.toggle() }
    @objc private func tryThemes() {
        let screens = NSScreen.screens
        let barIndices = screens.indices.filter { index in
            let id = (screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            return panels[id] != nil
        }
        guard let index = ThemeTrialPlacement.screenIndex(at: NSEvent.mouseLocation, frames: screens.map(\.frame),
                                                         mainIndex: screens.firstIndex { $0 === NSScreen.main },
                                                         barIndices: barIndices) else { return }
        showThemeTrial(on: screens[index])
    }

    private func showThemeTrial(on screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        guard let bar = panels[id] else { return }
        themeTrial.show(store: store, bar: bar, screen: screen)
    }

    @objc func showSetup() {
        setup.show(store: store,
            arrangeBar: { [weak self] in self?.store.barEditing.begin() },
            customizeWidgets: { [weak self] in
                guard let self else { return }
                customization.show(store: store, section: .widgets)
            },
            showProfile: { [weak self] name in
                guard let self else { return }
                customization.show(store: store, section: .profiles)
                store.onCustomizeProfile?(name)
            })
    }
    @objc private func showUserGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Seb-GRAF/StableBar/blob/main/docs/README.md")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCustomization()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.barEditing.end()
        themeTrial.cancel()
        store.flushCustomization()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.update?.stop()
        editingKeyboard.stop()
        editingControls.close()
        themeTrial.cancel()
        control?.stop()
        systemContext?.stop()
        store.stop()
    }
}
