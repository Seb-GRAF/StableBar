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
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if action == "list" {
                    print(String(decoding: try encoder.encode(packages.list()), as: UTF8.self))
                } else {
                    let inspection = try action == "install" ? packages.install(source!) : packages.inspect(source!)
                    print(String(decoding: try encoder.encode(inspection.manifest), as: UTF8.self))
                    print("Commands to review before enabling:")
                    for command in inspection.commands { print(command) }
                }
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
}

@MainActor
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: BarStore
    private let setup = SetupWindow()
    private let customization = CustomizationWindow()
    private var control: RuntimeControl?
    private var systemContext: SystemContext?
    private var panels: [CGDirectDisplayID: BarPanel] = [:]
    private var statusItem: NSStatusItem!

    init(configurationURL: URL) {
        store = BarStore(configurationURL: configurationURL)
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
        do {
            let control = RuntimeControl { [store] in try store.handle($0) }
            try control.start(url: store.configurationURL)
            self.control = control
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        Task {
            try? await loadLoginShellEnvironment()
            store.start()
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
        store.popup.close()
        store.retainDisplays(Set(NSScreen.screens.map { BarDisplay(screen: $0).id }))
        store.refreshContext()
        updatePanels()
        if store.configuration?.widgets.contains(where: { $0.enabled && ($0.content == .workspaces || $0.display == .active) }) == true {
            store.workspaceStore.start()
        }
    }

    @objc private func sleeping() { store.setSleeping(true) }

    @objc private func woke() {
        store.setSleeping(false)
        screensChanged()
        store.refreshScripts(for: "wake")
    }

    private func updatePanels() {
        guard let config = store.configuration else { return }
        let screens = NSScreen.screens
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
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
                panel.contentView = NSHostingView(rootView: BarView(store: store, display: BarDisplay(screen: screen)))
                panels[id] = panel
            }
            let host = panel.contentView as! NSHostingView<BarView>
            host.rootView = BarView(store: store, display: BarDisplay(screen: screen))
            let top = screen.frame.maxY
            let height = config.bar.height * config.bar.scale(for: BarDisplay(screen: screen))
            panel.setFrame(NSRect(x: screen.frame.minX, y: top - config.bar.offset - height,
                                  width: screen.frame.width, height: height), display: true)
            panel.orderFrontRegardless()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "StableBar", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        addItem("Customize StableBar…", action: #selector(showCustomization), to: menu)
        addItem("Set up StableBar…", action: #selector(showSetup), to: menu)
        addItem("Open configuration file…", action: #selector(openConfiguration), to: menu)
        addItem("Reload configuration", action: #selector(reloadConfiguration), to: menu)
        addItem("Reconnect \(store.workspaceStore.source.title)", action: #selector(reconnect), to: menu)
        if let error = store.configurationError ?? store.workspaceStore.error {
            menu.addItem(.separator())
            menu.addItem(withTitle: error, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        addItem("Quit StableBar", action: #selector(quit), to: menu)
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func showCustomization() { customization.show(store: store) }
    @objc func showSetup() { setup.show(store: store) }
    @objc private func openConfiguration() { store.openConfiguration() }
    @objc private func reloadConfiguration() { store.reloadConfiguration() }
    @objc private func reconnect() { store.workspaceStore.start() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCustomization()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        systemContext?.stop()
        store.stop()
    }
}
