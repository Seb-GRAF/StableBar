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
    let appWatcher = AppWatcher()
    let workspaceStore: WorkspaceStore
    let windowClearance = WindowClearance()
    let menuBarDelay = MenuBarDelay()
    let appMenu: AppMenu
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
        appWatcher.store = self
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
            widgetScripts.send(.workspace, ["INFO": (workspaceStore.source == .rift ? focused?.label : focused?.name) ?? "", "SID": String(focused?.monitor ?? appWatcher.activeDisplayID)])
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
        appWatcher.start()
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
        appWatcher.readAppMenu()
        appWatcher.readMenuBarItems()
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
        appWatcher.stop()
        appMenu.read(nil)
        appMenu.mirror.references = []
        configurationStore.reloadTask?.cancel()
        configurationStore.configurationWatcher.stop()
        workspaceStore.stop()
        workspaceStore.dockBadges.isWatching = false
        widgetScripts.stop()
        if let reloadObserver { DistributedNotificationCenter.default().removeObserver(reloadObserver) }
        reloadObserver = nil
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
