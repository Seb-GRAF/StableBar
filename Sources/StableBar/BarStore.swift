import AppKit
import Observation

enum WindowRequest {
    case customize
    case showCrashes
    case customizePackages
    case customizeItem(CustomizationTarget)
    case tryThemes(Int)
    case endThemeTrial
}

@MainActor @Observable
final class BarStore: NSObject {
    var configuration: Configuration?
    var configurationError: String?
    /// Properties the bar skips because a file was written for a newer release.
    var configurationWarning: String?
    var activeApp = NSWorkspace.shared.frontmostApplication
    var activeDisplayID = 1
    let workspaceStore: WorkspaceStore
    let windowClearance = WindowClearance()
    let menuBarDelay = MenuBarDelay()
    let appMenu: AppMenu
    /// The app whose menus the macOS menu bar shows, which App menus and the Apple menu follow, and how the bar
    /// hears that it changed: the returned object keeps the observation alive.
    @ObservationIgnored var menuBarApp: () -> NSRunningApplication? = { NSWorkspace.shared.menuBarOwningApplication }
    @ObservationIgnored var observeMenuBarApp: (@escaping @MainActor () -> Void) -> AnyObject = { changed in
        NSWorkspace.shared.observe(\.menuBarOwningApplication) { _, _ in MainActor.assumeIsolated { changed() } }
    }
    var crashReports = CrashReports()
    let popup: WidgetPopup
    let innerPopup = WidgetPopup()
    var update: AppUpdate?
    let configurationStore: ConfigurationStore
    let registry: DataSourceRegistry
    var onConfigurationChange: (() -> Void)?
    var onWindowRequest: ((WindowRequest) -> Void)?
    let pendingLinks = PendingLinks()
    var onCustomizeProfile: ((String) -> Void)?
    var onEndCustomizationEditing: (() -> Void)?
    var barPanel: (Int) -> BarPanel? = { _ in nil }
    var effectiveDocument: [String: ConfigurationValue] = [:]
    var screenDocuments: [String: [String: ConfigurationValue]] = [:]
    var origins: [String: ConfigurationOrigin] = [:]
    var contributions: [String: [ConfigurationContribution]] = [:]
    var widgetPackageNames: [String: String] = [:]
    var widgetPackageIDs: [String: String] = [:]
    var builtInWidgetIDs: Set<String> = []
    var activeProfiles: [String] = []
    var profiles: [ConfigurationProfile] = []
    var pinnedProfile: String?
    private let customizationSaveDelay: Duration
    @ObservationIgnored lazy var customizationHistory = ConfigurationHistory(store: self, saveDelay: customizationSaveDelay)
    @ObservationIgnored lazy var barEditing = BarEditing(store: self)
    @ObservationIgnored lazy var widgetScripts = WidgetScripts(store: self)
    @ObservationIgnored lazy var barPresentation = BarPresentation(store: self)
    @ObservationIgnored lazy var packageStoreClient = PackageStoreClient(
        packages: WidgetPackageStore(directory: configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages")),
        sources: configurationStore.packageSources.filter { !$0.isStore })
    @ObservationIgnored lazy var packageLibrary = PackageLibrary(store: self)
    var profileContext: ConfigurationContext { configurationStore.configurationLoader.profileContext }
    private(set) var managesConnections = false
    private var reloadObserver: NSObjectProtocol?
    private var menuBarAppObservation: AnyObject?

    init(configurationURL: URL = LaunchCommand.configurationURL, registry: DataSourceRegistry = .builtIn,
         popup: WidgetPopup = WidgetPopup(), themesDirectory: URL? = bundledThemesDirectory,
         customizationSaveDelay: Duration = .milliseconds(500), release: String? = AppVersion.release,
         appMenu: AppMenu = AppMenu()) {
        configurationStore = ConfigurationStore(configurationURL: configurationURL, themesDirectory: themesDirectory, release: release)
        self.appMenu = appMenu
        self.customizationSaveDelay = customizationSaveDelay
        self.registry = registry
        self.popup = popup
        workspaceStore = WorkspaceStore()
        super.init()
        configurationStore.store = self
        workspaceStore.onModeChange = { [weak self] mode in
            self?.barPresentation.updatePresentations()
            if self?.managesConnections == true { self?.widgetScripts.send(.aerospaceMode, ["INFO": mode ?? ""]) }
        }
    }

    func start(on setup: ScreenSetup? = nil) {
        configurationStore.context = SystemContext.current()
        reloadObserver = DistributedNotificationCenter.default().addObserver(
            forName: LaunchCommand.reloadNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configurationStore.reloadConfiguration() }
            }
        workspaceStore.onWorkspaceChange = { [weak self] in
            guard let self else { return }
            popup.close()
            let focused = workspaceStore.workspaces.first(where: \.isFocused)
            widgetScripts.send(.workspace, ["INFO": (workspaceStore.source == .rift ? focused?.label : focused?.name) ?? "", "SID": String(focused?.monitor ?? activeDisplayID)])
        }
        do {
            try configurationStore.createStarterAndMigrateFiles()
        } catch {
            configurationError = errorMessage(error)
        }
        if let setup {
            configurationStore.prepareScreenSetup(setup)
        }
        configurationStore.reloadConfiguration()
        packageLibrary.startUpdateChecks()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateActiveApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // The menus follow the menu bar rather than the front app: macOS hands the menu bar over a moment after it
        // announces an activation, and keeps it on the previous app while an agent without one is in front (#443).
        menuBarAppObservation = observeMenuBarApp { [weak self] in self?.readAppMenu() }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppMenu), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(readLaunchedAppMenuBarItems), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(readMenuBarItems), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshAppMenu), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func updateActiveApp() {
        activeApp = NSWorkspace.shared.frontmostApplication
        if let screen = NSScreen.main { activeDisplayID = BarDisplay(screen: screen).id }
        popup.close()
        configurationStore.refreshContext()
        widgetScripts.send(.frontApp, ["INFO": activeApp?.localizedName ?? "Desktop"])
    }

    private func readAppMenu() {
        let shown = configuration?.widgets.contains { widget in
            switch widget.content {
            case .appMenu, .appleMenu(click: .menu): widget.enabled
            default: false
            }
        } == true
        appMenu.read(shown ? menuBarApp() : nil)
    }

    @objc private func refreshAppMenu() {
        activeApp = NSWorkspace.shared.frontmostApplication
        readAppMenu()
    }

    @objc private func readMenuBarItems() {
        guard configuration?.widgets.contains(where: { $0.enabled && $0.drawsMenuBarItems }) == true else { return }
        Task { _ = await appMenu.readMenuBarItems(requestingAccess: false) }
    }

    @objc private func readLaunchedAppMenuBarItems() {
        Task {
            for delay in [1, 5] {
                try? await Task.sleep(for: .seconds(delay))
                readMenuBarItems()
            }
        }
    }

    func move(_ source: MenuBarItemSource, to placement: MenuBarItemPlacement, before index: Int?, in widget: WidgetConfiguration) {
        guard case let .menuBarItems(_, _, _, hidden) = widget.content else { return }
        let properties = menuBarItemsProperties(shown: widget.shownMenuBarItems, hidden: hidden, moving: source, to: placement, before: index,
                                                among: appMenu.menuBarItems)
        do {
            try customizationHistory.change(ConfigurationEdit(action: .set, id: widget.id, properties: properties))
            if widgetScripts.actionErrors[widget.id] != nil { widgetScripts.actionErrors[widget.id] = nil }
        } catch {
            widgetScripts.actionErrors[widget.id] = errorMessage(error)
        }
    }

    /// Selects the keyboard input source with `id`, or without one, the next, for a click on `widget`.
    func selectInputSource(_ id: String?, widget: WidgetConfiguration) {
        do {
            try InputSourceMonitor.select(id)
            if widgetScripts.actionErrors[widget.id] != nil { widgetScripts.actionErrors[widget.id] = nil }
        } catch {
            widgetScripts.actionErrors[widget.id] = errorMessage(error)
        }
    }

    /// Makes the audio device with `id` the default output, for a click on `widget`.
    func selectOutputDevice(_ id: String, widget: WidgetConfiguration) {
        do {
            try AudioMonitor.setOutputDevice(id)
            if widgetScripts.actionErrors[widget.id] != nil { widgetScripts.actionErrors[widget.id] = nil }
        } catch {
            widgetScripts.actionErrors[widget.id] = errorMessage(error)
        }
    }

    /// Takes what `loader` read besides the configuration itself: profiles, packages and contributions.
    private func adopt(_ loader: ConfigurationLoader) {
        profiles = loader.profiles
        pinnedProfile = loader.pinnedProfile
        widgetPackageNames = loader.widgetPackageNames
        widgetPackageIDs = loader.widgetPackageIDs
        builtInWidgetIDs = loader.builtInWidgetIDs
        contributions = loader.contributions
        configurationWarning = loader.newerVersionWarning
    }

    /// Shows `next` as `loader` read it for `context`, in `setup`, without starting its scripts,
    /// providers, window managers or app reading: what a render draws. Its scripts are the caller's.
    func showWithoutRunning(_ next: Configuration, loader: ConfigurationLoader, context: ConfigurationContext, setup: ScreenSetup) {
        configurationStore.configurationLoader = loader
        configurationStore.context = context
        configurationStore.screenSetup = setup
        adopt(loader)
        configuration = next
        effectiveDocument = loader.document
        origins = loader.origins
        activeProfiles = loader.activeProfiles
        screenDocuments = loader.screenDocuments
        barPresentation.preparePresentations()
    }

    func display(_ next: Configuration, loader: ConfigurationLoader) {
        let profilesChanged = profiles != loader.profiles
        adopt(loader)
        if effectiveDocument == loader.document, screenDocuments == loader.screenDocuments, configuration?.providers == next.providers {
            origins = loader.origins
            activeProfiles = loader.activeProfiles
            configurationError = nil
            // A profile that doesn't change the bar can still need the Wi-Fi network, camera or microphone watched.
            if profilesChanged { onConfigurationChange?() }
            return
        }
        popup.close()
        widgetScripts.run(next)
        configuration = next
        managesConnections = true
        readAppMenu()
        readMenuBarItems()
        appMenu.mirror.references = next.liveMenuBarItems
        barPresentation.preparePresentations()
        effectiveDocument = loader.document
        let sources = configurationStore.packageSources.filter { !$0.isStore }
        Task { [packageStoreClient] in await packageStoreClient.setPrivateSources(sources) }
        screenDocuments = loader.screenDocuments
        origins = loader.origins
        activeProfiles = loader.activeProfiles
        configurationError = nil
        widgetScripts.observeEvents(of: next)
        widgetScripts.updateSuspension()
        onConfigurationChange?()
    }

    func setPopupVisibleWidget(_ id: String?, anchor: NSView? = nil) {
        widgetScripts.popupWidgetID = id
        appMenu.closeSubmenus(after: nil)
        innerPopup.close()
        let anchor = anchor.map(ObjectIdentifier.init)
        for (widgetID, presentation) in barPresentation.presentations { presentation.setPopupAnchor(widgetID == id ? anchor : nil) }
        widgetScripts.updateSuspension()
    }

    func setInnerPopupAnchor(_ anchor: NSView?, of id: String) {
        appMenu.closeSubmenus(after: nil)
        barPresentation.presentations[id]?.setInnerPopupAnchor(anchor.map(ObjectIdentifier.init))
    }

    /// Runs again what started with the app's own environment while the login shell's was still being read.
    func loginShellEnvironmentLoaded() {
        workspaceStore.reconnect()
        var restarted = Set<ObjectIdentifier>()
        for script in Array(widgetScripts.scripts.values) + Array(widgetScripts.providers.values) where restarted.insert(ObjectIdentifier(script)).inserted {
            script.refresh(ScriptEvent(sender: "startup"))
        }
    }

    func handle(_ request: RuntimeRequest) throws -> ConfigurationValue {
        switch request.action {
        case .report:
            return try JSONDecoder().decode(ConfigurationValue.self, from: JSONEncoder().encode(liveReport()))
        case .status:
            return .object(AppVersion().fields.merging(["running": .bool(true), "pid": .number(Double(getpid())),
                                                        "configuration": .string(configurationStore.sharedConfigurationURL.path)]) { $1 })
        case .quit:
            // Terminating right away would exit before the command gets its reply.
            Task { NSApp.terminate(nil) }
        case .customize:
            if let id = request.id { onWindowRequest?(.customizeItem(.widget(id))) }
            else { onWindowRequest?(.customize) }
        case .reload:
            barEditing.end()
            try configurationStore.applyEdits([], persist: false)
        case .batch: try configurationStore.applyEdits(request.edits ?? [], persist: request.persist)
        case .uninstallPackage:
            guard let id = request.id, let version = request.version else {
                throw CommandFailure(message: "Uninstall requires a package id and version.")
            }
            try configurationStore.uninstallPackage(id: id, version: version)
        case .reset: try configurationStore.setSessionEdits([])
        case .refresh:
            guard let id = request.id, let script = widgetScripts.scripts[id] else { throw CommandFailure(message: "Refresh requires a running widget id.") }
            guard !script.diagnostics.suspended else {
                throw CommandFailure(message: "Widget is suspended. Choose Resume for testing in Status or make a consumer visible before refreshing.")
            }
            widgetScripts.refresh(configuration!.widgets.first { $0.id == id }!, event: ScriptEvent(sender: "manual"))
        case .closePopup where request.id == nil:
            popup.closeAll()
        case .popup, .openPopup, .closePopup:
            guard let id = request.id, configuration?.widgets.contains(where: { $0.id == id }) == true else {
                throw CommandFailure(message: "Unknown widget: \(request.id ?? "").")
            }
            // Duration traps on more seconds than it can hold, which would crash the bar.
            if let duration = request.duration, duration <= 0 || duration > 86_400 {
                throw CommandFailure(message: "--duration must be greater than zero and at most one day (86400 seconds).")
            }
            if widgetScripts.popupWidgetID == id || popup.pins.ids.contains(id) {
                if request.action == .openPopup { break }
                if widgetScripts.popupWidgetID == id { popup.close() } else { popup.closePinned(id) }
                break
            }
            if request.action == .closePopup { break }
            func find(_ name: String, in view: NSView) -> NSView? {
                view.identifier?.rawValue == name ? view : view.subviews.lazy.compactMap { find(name, in: $0) }.first
            }
            let activeID = workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? activeDisplayID
            guard let bar = barPanel(activeID),
                  let widget = barEditing.widgets(on: BarDisplay(screen: bar.screen!)).first(where: { $0.id == id }),
                  let anchor = find(id, in: bar.contentView!)
                    ?? find(BarView.moreWidgetsID(widget.position, notched: configuration!.bar(on: ScreenKind(BarDisplay(screen: bar.screen!)))
                        .notch(on: BarDisplay(screen: bar.screen!)) != nil), in: bar.contentView!) else {
                throw CommandFailure(message: "Widget \(id) is not on the bar of the active display.")
            }
            guard let content = widgetPopup(widget, store: self) else {
                throw CommandFailure(message: "Widget \(id) has no popup or menu.")
            }
            let config = configuration!.onScreen(ScreenKind(BarDisplay(screen: bar.screen!)))
            popup.open(content, widget: widget, defaults: config.popupDefaults.popupStyle(over: config.defaults),
                       store: self, anchor: anchor, onHover: false)
            if let duration = request.duration { popup.close(after: .seconds(duration)) }
        case .focus:
            let activeID = workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? activeDisplayID
            guard let bar = barPanel(activeID) else { throw CommandFailure(message: "No bar on the active display.") }
            bar.focusWidgets()
        case .trigger:
            guard let event = request.id else { throw CommandFailure(message: "Trigger requires an event name.") }
            widgetScripts.refreshScripts(for: event, environment: withoutShellVariables(request.environment ?? [:]))
        case .query: break
        // AppDelegate, which owns the bar's windows, hides or shows them before passing these on.
        case .hide, .show, .toggle: break
        }
        return try snapshot(id: request.action == .query ? request.id : nil)
    }

    func snapshot(id: String? = nil) throws -> ConfigurationValue {
        if let id {
            let definitions = try effectiveDocument["widgets"]?.decoded([[String: ConfigurationValue]].self) ?? []
            guard let definition = definitions.first(where: { $0["id"] == .string(id) }) else {
                throw CommandFailure(message: "Unknown widget: \(id).")
            }
            var result: [String: ConfigurationValue] = ["configuration": .object(definition),
                "defaults": effectiveDocument["defaults"] ?? .object([:]),
                "origins": .object(origins.filter { $0.key.hasPrefix("widgets.\(id).") }.mapValues { .string($0.description) })]
            result["mode"] = workspaceStore.mode.map(ConfigurationValue.string) ?? .null
            result["modeStates"] = .array(StyleStates(mode: barPresentation.modePresentation).names.map(ConfigurationValue.string))
            result["modeConnectionError"] = workspaceStore.connectionError.map(ConfigurationValue.string) ?? .null
            if let widget = configuration?.widgets.first(where: { $0.id == id }) {
                let prefixes = ["widgets.\(id)", "defaults", "popupDefaults", "workspaceDefaults", "modeAliases", "roles"]
                    + (widget.popupName.map { ["popups.\($0)"] } ?? [])
                result["origins"] = .object(origins.filter { entry in
                    prefixes.contains { entry.key == $0 || entry.key.hasPrefix($0 + ".") }
                }.mapValues { .string($0.description) })
                result["role"] = widget.role.map { .string($0.rawValue) } ?? .null
                result["resolvedStyle"] = barPresentation.presentations[id]?.style.style(hovered: false).configurationValue ?? .object([:])
                result["presentationLayers"] = .array(presentationLayers(for: widget))
                if widget.content == .workspaces {
                    result["workspacePresentation"] = .object(try configuration!.workspaceDefaults.mergedProperties(definition["workspace"]))
                }
                let shown = label(for: widget)
                result["text"] = .string(shown.text)
                result["icon"] = shown.icon.map(ConfigurationValue.string) ?? .null
                result["fields"] = .object(shown.fields.mapValues(ConfigurationValue.string))
            }
            if let script = widgetScripts.scripts[id] {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                result["diagnostics"] = try JSONDecoder().decode(ConfigurationValue.self, from: encoder.encode(script.diagnostics))
                result["samples"] = .array(script.samples.map(ConfigurationValue.number))
                result["latestOutput"] = (try? JSONDecoder().decode(ConfigurationValue.self, from: Data(script.diagnostics.lastStdout.utf8)))
                    ?? .string(script.diagnostics.lastStdout)
                result["error"] = script.error.map(ConfigurationValue.string) ?? .null
                result["values"] = .object((script.output.values ?? [:]).mapValues(ConfigurationValue.number))
                result["state"] = barPresentation.presentations[id]?.style.state.map(ConfigurationValue.string) ?? .null
                result["temporaryFields"] = barPresentation.presentations[id]?.temporaryFields
                    .map { ConfigurationValue.object($0.mapValues(ConfigurationValue.string)) } ?? .null
                if let name = configuration?.widgets.first(where: { $0.id == id })?.providerName,
                   let provider = configuration?.providers[name], let type = registry[provider.type] {
                    result["source"] = .object(["provider": .string(name), "type": .string(type.name), "push": .bool(type.continuous),
                                                "events": .array(type.events.map { .string($0.rawValue) })])
                }
            }
            return .object(result)
        }
        let barLayers: [ConfigurationValue] = [.object(["source": .string("bar.style"),
            "style": configuration?.bar.style.configurationValue ?? .object([:])])]
            + (configuration?.widgets ?? []).compactMap { widget in
                widgetScripts.scripts[widget.id]?.output.barStyle.map { .object(["source": .string("output.\(widget.id).barStyle"),
                                                                 "style": $0.configurationValue]) }
            }
        return .object(["configuration": .object(effectiveDocument),
                        "mode": workspaceStore.mode.map(ConfigurationValue.string) ?? .null,
                        "modeStates": .array(StyleStates(mode: barPresentation.modePresentation).names.map(ConfigurationValue.string)),
                        "modeConnectionError": workspaceStore.connectionError.map(ConfigurationValue.string) ?? .null,
                        "resolvedBarStyle": barPresentation.barStyle.configurationValue,
                        "barPresentationLayers": .array(barLayers),
                        "origins": .object(origins.mapValues { .string($0.description) }),
                        "profiles": .array(activeProfiles.map(ConfigurationValue.string)),
                        "sessionEdits": .number(Double(configurationStore.sessionEdits.count)),
                        "popup": widgetScripts.popupWidgetID.map(ConfigurationValue.string) ?? .null,
                        "error": configurationError.map(ConfigurationValue.string) ?? .null,
                        "warning": configurationWarning.map(ConfigurationValue.string) ?? .null].merging(AppVersion().fields) { $1 })
    }

    private func presentationLayers(for widget: WidgetConfiguration) -> [ConfigurationValue] {
        guard let configuration else { return [] }
        func layer(_ source: String, _ style: WidgetStyle) -> ConfigurationValue {
            .object(["source": .string(source), "style": style.configurationValue])
        }
        var layers = [layer("defaults", configuration.defaults)]
        if let role = widget.role { layers.append(layer("roles.\(role.rawValue)", configuration.roleStyle(role))) }
        layers.append(layer("widgets.\(widget.id).style", widget.style))
        if let background = widget.background {
            layers.append(layer("widgets.\(widget.id).background", WidgetStyle(background: background)))
        }
        for source in configuration.widgets {
            if let style = widgetScripts.scripts[source.id]?.output.widgetStyles?[widget.id] {
                layers.append(layer("output.\(source.id).widgetStyles.\(widget.id)", style))
            }
        }
        if let own = widgetScripts.scripts[widget.id]?.output {
            if let style = own.style { layers.append(layer("output.\(widget.id).style", style)) }
            if let color = own.color { layers.append(layer("output.\(widget.id).color", WidgetStyle(foreground: color))) }
        }
        return layers
    }

    func openConfiguration() {
        NSWorkspace.shared.open(configurationStore.configurationURL)
    }

    /// Keeps the last `stablebar://` link StableBar opens for Settings and returns its section.
    func receive(_ urls: [URL]) -> CustomizationSection? {
        for url in urls.reversed() {
            do {
                if let link = try ThemeLink(url: url) {
                    pendingLinks.theme?.discard()
                    pendingLinks.theme = try ThemeLinkCandidate(link: link, store: self)
                    pendingLinks.themeError = nil
                    return .appearance
                }
            } catch {
                pendingLinks.theme?.discard()
                pendingLinks.theme = nil
                pendingLinks.themeError = errorMessage(error)
                return .appearance
            }
            do {
                if let link = try BarLink(url: url) {
                    pendingLinks.bar?.discard()
                    pendingLinks.bar = try BarLinkCandidate(link: link, store: self)
                    pendingLinks.barError = nil
                    return .appearance
                }
            } catch {
                pendingLinks.bar?.discard()
                pendingLinks.bar = nil
                pendingLinks.barError = errorMessage(error)
                return .appearance
            }
            if let link = PackageSourceLink(url: url) {
                pendingLinks.source = link
            } else if let link = PackageLink(url: url) {
                pendingLinks.package = link
            } else {
                continue
            }
            return .packages
        }
        return nil
    }

    func stop() {
        packageLibrary.stopUpdateChecks()
        barEditing.end()
        configurationStore.endThemeTrial()
        pendingLinks.theme?.discard()
        pendingLinks.theme = nil
        pendingLinks.bar?.discard()
        pendingLinks.bar = nil
        configurationStore.flushCustomization()
        managesConnections = false
        popup.closeAll()
        windowClearance.stop()
        menuBarDelay.stop()
        menuBarAppObservation = nil
        appMenu.read(nil)
        appMenu.mirror.references = []
        configurationStore.reloadTask?.cancel()
        configurationStore.configurationWatcher.stop()
        workspaceStore.stop()
        workspaceStore.dockBadges.isWatching = false
        widgetScripts.stop()
        if let reloadObserver { DistributedNotificationCenter.default().removeObserver(reloadObserver) }
        reloadObserver = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

extension BarStore {
    /// What only the running bar knows for a bug report: access, the workspace connection, active profiles and problems.
    func liveReport() -> BugReport.Live {
        let widgets = configuration?.widgets ?? []
        let names = WidgetDisplayName.names(for: widgets, packageNames: widgetPackageNames, providers: configuration?.providers ?? [:])
        let failures = widgets.compactMap { widget -> String? in
            guard case let .failed(error) = widgetScripts.widgetStatus(for: widget) else { return nil }
            return "Widget \(names[widget.id] ?? widget.id): \(error)"
        }
        let workspaces = if !widgets.contains(where: { $0.content == .workspaces }) { "" }
            else {
                switch workspaceStore.connectionStatus {
                case let .failed(error): "error: \(error)"
                case .connected: "connected"
                case .notInUse: "not connected"
                }
            }
        return BugReport.Live(access: BugReport.access(), workspaces: workspaces, profiles: activeProfiles,
                              problems: [configurationError, configurationWarning].compactMap { $0 } + failures)
    }

    func bugReport() async -> BugReport {
        await BugReport.gather(configuration: configurationStore.configurationURL, live: liveReport(), path: shellEnvironment.withLock { $0["PATH"] ?? "" })
    }
}
