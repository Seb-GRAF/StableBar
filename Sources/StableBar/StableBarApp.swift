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
                if let warning = loader.newerVersionWarning { FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8)) }
            case let .control(url, request):
                let result = try RuntimeControl.send(request, url: url)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            case let .packages(url, action, source):
                let packages = WidgetPackageStore(directory: url.deletingLastPathComponent().appending(path: "packages"))
                if action == "list" {
                    print(String(decoding: try packageListing(packages), as: UTF8.self))
                } else {
                    try printReview(action == "install" ? packages.install(source!) : packages.inspect(source!))
                }
            case let .installFromStore(url, id, source):
                let packages = WidgetPackageStore(directory: url.deletingLastPathComponent().appending(path: "packages"))
                // Without a configuration file, only the Store is configured.
                let sources = FileManager.default.fileExists(atPath: url.path) ? try PackageSource.configured(at: url) : []
                let client = PackageStoreClient(packages: packages, sources: sources.filter { !$0.isStore })
                Task {
                    do {
                        try printReview(await client.install(id: id, from: source))
                    } catch {
                        FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
                        exit(1)
                    }
                    exit(0)
                }
                dispatchMain()
            case let .buildSource(packages, output, previous, url, name):
                Task {
                    do {
                        let build = try await PackageSourceBuilder(packages: packages, output: output, previous: previous).build()
                        print("Index lists \(build.ids.count) \(build.ids.count == 1 ? "package" : "packages"): \(build.ids.joined(separator: ", ")).")
                        print(build.written.isEmpty ? "No new files for the packages. Upload \(output.path)/index.json."
                              : "Upload these new files and index.json from \(output.path):")
                        for file in build.written { print("  \(file)") }
                        if let url, let name {
                            let id = PackageSource.newID(for: name, taken: [])
                            print("Join link: \(PackageSourceLink(id: id, name: name, url: url).link.absoluteString)")
                        }
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
            case let .renderScenes(output, scenes):
                NSApplication.shared.setActivationPolicy(.accessory)
                Task {
                    let report = await SceneRenderer.renderAll(scenes, to: output)
                    if report.failures > 0 {
                        FileHandle.standardError.write(Data("\(report.failures) scene(s) failed; see \(output.appending(path: "scenes.json").path)\n".utf8))
                    }
                    exit(report.failures > 0 ? 1 : 0)
                }
                NSApplication.shared.run()
            case let .triage(url, agent, model):
                try Triage.run(configuration: url, agent: agent, model: model)
            case let .triageContext(url):
                print(try Triage.writeContext(configuration: url).path)
            case let .report(url):
                // A bar running with this configuration adds what only it knows; without one, the report says what's missing.
                let live = try? RuntimeControl.send(RuntimeRequest(action: .report), url: url).decoded(BugReport.Live.self)
                Task {
                    print(await BugReport.gather(configuration: url, live: live, barRunning: RuntimeControl.isRunning(url: url),
                                                 path: ProcessInfo.processInfo.environment["PATH"] ?? "").markdown)
                    exit(0)
                }
                dispatchMain()
            case let .uninstall(removesConfiguration, showsMenuBar, confirmed):
                Task {
                    exit(await UninstallCommand.run(removesConfiguration: removesConfiguration, showsMenuBar: showsMenuBar, confirmed: confirmed))
                }
                dispatchMain()
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
    /// The workspace cell under the current drag, which the bar takes on its cells' behalf.
    weak var workspaceDropTarget: WorkspaceWindowDropTargetView?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        registerForDraggedTypes([WorkspaceWindowDragSourceView.pasteboardType])
    }

    var drawingFrame: CGRect {
        guard barGeometry?.outsideExtent ?? 0 > 0 else { return frame }
        let height = barGeometry?.panelHeight ?? frame.height
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    override var canBecomeKey: Bool { isEditingBar }
    override var canBecomeMain: Bool { false }
    @objc var hasKeyAppearance: Bool { true }

    override var level: NSWindow.Level {
        didSet { decorationPanel?.level = level }
    }

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
    private let menuBarStrip = MenuBarStrip()
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
        MenuBarAutoHide.forgetIfShown()
        NSApp.mainMenu = EditMenu.make()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "StableBar")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.onConfigurationChange = { [weak self] in self?.updatePanels() }
        store.onCustomize = { [weak self] in self?.showCustomization() }
        store.onShowCrashes = { [weak self] in self?.showCrashes() }
        store.onCustomizePackages = { [weak self] in
            guard let self else { return }
            customization.show(store: store, section: .packages)
        }
        store.onCustomizeWidget = { [weak self] id in
            guard let self else { return }
            customization.show(store: store, widgetID: id)
        }
        store.onEndThemeTrial = { [weak self] in self?.themeTrial.cancel() }
        store.barPanel = { [weak self] displayID in
            self?.panels.values.first { $0.screen.map(BarDisplay.init)?.id == displayID }
        }
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
            let environment = Task {
                let variables = try await readLoginShellEnvironment()
                shellEnvironment.withLock { $0 = variables }
            }
            // A profile can take much longer to read right after login, so the bar starts after 10 seconds
            // at most, and what started with the app's own environment runs again once the shell's arrives.
            let loaded = await environment.finishes(within: .seconds(10))
            store.start(on: ScreenSetup(NSScreen.screens.map(BarDisplay.init)))
            if !loaded {
                Task { [store] in
                    if (try? await environment.value) != nil { store.loginShellEnvironmentLoaded() }
                }
            }
            systemContext = SystemContext { [store] in store.refreshContext() }
            systemContext!.start()
            if !UserDefaults.standard.bool(forKey: "setupCompleted") { showSetup() }
            await store.crashReports.refresh()
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
        store.menuBarDelay.stop()
        menuBarStrip.stop()
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
        menuBarStrip.update(panels: panels)
        editingControls.update(store: store, bars: panels, visibleFrames: visibleFrames)
        store.windowClearance.update(windows: store.clearanceConfiguration?.bar.keepWindowsClear == true,
                                     notifications: store.clearanceConfiguration?.bar.keepNotificationsClear == true,
                                     displays: clearanceDisplays)
        store.menuBarDelay.update(milliseconds: config.bar.menuBarRevealDelay, menuBars: screens.map {
            CGRect(x: $0.frame.minX, y: screens[0].frame.maxY - $0.frame.maxY, width: $0.frame.width,
                   height: max(NSStatusBar.system.thickness, $0.safeAreaInsets.top))
        })
        store.appMenu.hidesMenuBar = config.bar.hideMenuBar
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
        let error = store.configurationError ?? store.workspaceStore.error ?? store.configurationWarning
        let note = store.crashReports.note
        if error != nil || note != nil { menu.addItem(.separator()) }
        if let error { menu.addItem(withTitle: error, action: nil, keyEquivalent: "") }
        if let note { addItem(note, action: #selector(showCrashes), to: menu) }
        Task { await store.crashReports.refresh() }
        menu.addItem(.separator())
        addItem("Settings…", action: #selector(showCustomization), to: menu)
        addItem("Quit StableBar", action: #selector(quit), to: menu)
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func showCustomization() { customization.show(store: store) }
    @objc private func showCrashes() { customization.showCrashes(store: store) }
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

    /// `stablebar://add-source` opens Settings › Packages with the Add source form filled in, and `stablebar://package`
    /// opens it on a package; nothing is added until the user confirms.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard store.receive(urls) else { return }
        customization.show(store: store, section: .packages)
    }

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
        store.appMenu.hidesMenuBar = false
    }
}
