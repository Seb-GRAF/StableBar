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
    /// The main configuration: the shared bar of every screen setup without its own.
    let sharedConfigurationURL: URL
    /// The release this bar runs as, which reads and stamps its files; nil in development builds.
    let release: String?
    /// The file of the bar on the screens: the shared bar, or the current screen setup's own bar.
    private(set) var configurationURL: URL
    private(set) var screenSetup: ScreenSetup?
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
    var sessionEdits: [ConfigurationEdit] = []
    private(set) var customizationEdits: [ConfigurationEdit] = []
    private var customizationBase: (Configuration, ConfigurationLoader)?
    private var customizationPreview: (data: Data, configuration: Configuration, loader: ConfigurationLoader)?
    private let customizationSaveDelay: Duration
    @ObservationIgnored lazy var customizationHistory = ConfigurationHistory(store: self, saveDelay: customizationSaveDelay)
    @ObservationIgnored lazy var barEditing = BarEditing(store: self)
    @ObservationIgnored lazy var widgetScripts = WidgetScripts(store: self)
    @ObservationIgnored lazy var barPresentation = BarPresentation(store: self)
    @ObservationIgnored lazy var packageStoreClient = PackageStoreClient(
        packages: WidgetPackageStore(directory: configurationURL.deletingLastPathComponent().appending(path: "packages")),
        sources: packageSources.filter { !$0.isStore })
    @ObservationIgnored lazy var packageLibrary = PackageLibrary(store: self)
    var themesDirectory: URL? { configurationLoader.themesDirectory }
    var profileContext: ConfigurationContext { configurationLoader.profileContext }
    /// The Store and the configured private sources. An invalid list leaves only the Store.
    var packageSources: [PackageSource] { (try? PackageSource.configured(in: effectiveDocument)) ?? [.store] }
    var context = ConfigurationContext()
    private var configurationLoader = ConfigurationLoader()
    // A trial changes the displayed composition, never the saved or command-line edits.
    private var normalComposition: (configuration: Configuration, loader: ConfigurationLoader)?
    private var triedTheme: (choice: ThemeChoice, edits: [ConfigurationEdit])?
    private(set) var managesConnections = false
    private let configurationWatcher = ConfigurationWatcher()
    private(set) var reloadTask: Task<Void, Never>?
    private var reloadObserver: NSObjectProtocol?
    private var menuBarAppObservation: AnyObject?

    init(configurationURL: URL = LaunchCommand.configurationURL, registry: DataSourceRegistry = .builtIn,
         popup: WidgetPopup = WidgetPopup(), themesDirectory: URL? = bundledThemesDirectory,
         customizationSaveDelay: Duration = .milliseconds(500), release: String? = AppVersion.release,
         appMenu: AppMenu = AppMenu()) {
        self.configurationURL = configurationURL
        self.appMenu = appMenu
        sharedConfigurationURL = configurationURL
        self.release = release
        self.customizationSaveDelay = customizationSaveDelay
        self.registry = registry
        self.popup = popup
        workspaceStore = WorkspaceStore()
        super.init()
        configurationLoader.themesDirectory = themesDirectory
        configurationLoader.appVersion = release
        configurationWatcher.onChange = { [weak self] in self?.scheduleReload() }
        workspaceStore.onModeChange = { [weak self] mode in
            self?.barPresentation.updatePresentations()
            if self?.managesConnections == true { self?.widgetScripts.send(.aerospaceMode, ["INFO": mode ?? ""]) }
        }
    }

    func start(on setup: ScreenSetup? = nil) {
        context = SystemContext.current()
        reloadObserver = DistributedNotificationCenter.default().addObserver(
            forName: LaunchCommand.reloadNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadConfiguration() }
            }
        workspaceStore.onWorkspaceChange = { [weak self] in
            guard let self else { return }
            popup.close()
            let focused = workspaceStore.workspaces.first(where: \.isFocused)
            widgetScripts.send(.workspace, ["INFO": (workspaceStore.source == .rift ? focused?.label : focused?.name) ?? "", "SID": String(focused?.monitor ?? activeDisplayID)])
        }
        do {
            let directory = sharedConfigurationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            SetupPreferences.rememberStarterClockFormat()
            if !FileManager.default.fileExists(atPath: sharedConfigurationURL.path) {
                let template = Bundle.main.url(forResource: "config", withExtension: "json")!
                let placement: SetupPreferences.Placement = UserDefaults.standard.bool(forKey: "_HIHideMenuBar") ? .current : .belowMenuBar
                // Below a visible menu bar, the starter is the one with Workspaces, System and Sound. Its manager is one
                // the workspace connection can reach: on the login shell's PATH.
                let workspaces = WorkspaceSource.detected(path: shellEnvironment.withLock { $0["PATH", default: ""] }, configured: nil)
                // A new configuration's clock follows the Mac's date order and 12- or 24-hour time.
                let starter = try SetupPreferences.withMacsClock(Data(contentsOf: template))
                let data = try SetupPreferences(placement: placement, workspaces: workspaces).applying(to: starter)
                try writeConfiguration(data, to: sharedConfigurationURL)
            }
            // The colors go first: they skip a file pinned to a release, and the other migrations pin it.
            try migrateEarlierColors(sharedConfigurationURL, savedBy: release)
            try migrateConfigurationFile(sharedConfigurationURL, savedBy: release)
            try migrateStarterAppleLogo(sharedConfigurationURL, savedBy: release)
            for url in screenSetupsWithOwnBars.map(ownBarURL(for:)) {
                try? migrateEarlierColors(url, savedBy: release)
                try? migrateConfigurationFile(url, savedBy: release)
                try? migrateStarterAppleLogo(url, savedBy: release)
            }
            // Earlier setups put a bar below the menu bar at the status bar's thickness or the main display's notch height.
            // Once, while the menu bar shows and covers part of such a bar, it moves under each display's own menu bar.
            if !UserDefaults.standard.bool(forKey: "migratedEarlierBelowMenuBarOffset") && !MenuBarAutoHide.isOn() {
                let offsets = Set([22, Double(NSStatusBar.system.thickness)]
                    + NSScreen.screens.map { Double($0.safeAreaInsets.top) }.filter { $0 > 0 })
                try migrateEarlierBelowMenuBarOffset(sharedConfigurationURL, offsets: offsets)
                // An own bar that can't be listed or read is retried at a later launch, without an error on the bar.
                let ownBars = try? ownBarSetups().map { setup in
                    (try? migrateEarlierBelowMenuBarOffset(ownBarURL(for: setup), offsets: offsets)) != nil
                }
                if let ownBars, !ownBars.contains(false) {
                    UserDefaults.standard.set(true, forKey: "migratedEarlierBelowMenuBarOffset")
                }
            }
        } catch {
            configurationError = errorMessage(error)
        }
        if let setup {
            prepareScreenSetup(setup)
        }
        reloadConfiguration()
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
        refreshContext()
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

    func refreshContext(_ next: ConfigurationContext? = nil) {
        let next = next ?? SystemContext.current(checking: profiles.filter(\.enabled))
        var nextWithSameAppAndDisplays = next
        nextWithSameAppAndDisplays.app = context.app
        nextWithSameAppAndDisplays.displays = context.displays
        let reload = nextWithSameAppAndDisplays != context || (next.app != context.app && configurationLoader.matchesApps)
            || (next.displays != context.displays && configurationLoader.matchesDisplays)
        context = next
        if reload { readConfiguration(leavingEditMode: false) }
    }

    func scheduleReload() {
        reloadTask?.cancel()
        let generation = configurationWatcher.generation
        reloadTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard configurationWatcher.generation == generation else { return }
                reloadConfiguration()
            } catch {}
        }
    }

    func reloadConfiguration() {
        readConfiguration(leavingEditMode: true)
    }

    func previewProfile(_ name: String?) {
        configurationLoader.previewProfile = name
        readConfiguration(leavingEditMode: false)
    }

    private func readConfiguration(leavingEditMode: Bool) {
        if leavingEditMode { barEditing.end() }
        defer { configurationWatcher.watch(configurationLoader.dependencies) }
        customizationPreview = nil
        customizationHistory.checkForExternalChanges()
        do {
            let base = try configurationLoader.load(configurationURL, context: context)
            let next: Configuration
            if !customizationEdits.isEmpty {
                let edits = try customizationHistory.pendingEdits()
                let data = try customizationData(edits, editing: Data(contentsOf: configurationURL))
                let (preview, loader) = try configurationReplayingSession(over: data)
                customizationEdits = edits
                configurationLoader = loader
                next = preview
            } else if sessionEdits.isEmpty { next = base }
            else {
                let root = try editedDocument([])
                next = try configurationLoader.load(configurationURL, data: configurationData(root), context: context)
            }
            apply(next)
        } catch {
            configurationError = errorMessage(error)
        }
    }

    private var configurationEditing: ConfigurationEditing {
        ConfigurationEditing(configurationURL: configurationURL, configurationLoader: configurationLoader, context: context,
                             sessionEdits: sessionEdits, customizationEdits: customizationEdits, release: release)
    }

    func editedDocument(_ edits: [ConfigurationEdit], data: Data? = nil, replaying: [ConfigurationEdit]? = nil) throws -> [String: ConfigurationValue] {
        try configurationEditing.editedDocument(edits, data: data, replaying: replaying)
    }

    private func applying(_ edit: ConfigurationEdit, to root: [String: ConfigurationValue], widgetIDs: inout [String],
                          widgetPackageIDs: [String: String]) throws -> [String: ConfigurationValue] {
        try configurationEditing.applying(edit, to: root, widgetIDs: &widgetIDs, widgetPackageIDs: widgetPackageIDs)
    }

    func editedMainDocument(data: Data? = nil, replaying: [ConfigurationEdit]? = nil) throws -> [String: ConfigurationValue] {
        try configurationEditing.editedMainDocument(data: data, replaying: replaying)
    }

    func requireSavedWidget(_ id: String) throws {
        try configurationEditing.requireSavedWidget(id, widgets: configuration?.widgets ?? [])
    }

    struct PreparedWidgetMove: Sendable {
        let before: Data
        let after: Data
        let configuration: Configuration
        let loader: ConfigurationLoader
        let generation: Int
    }

    func prepareWidgetMove(_ id: String, edits: [ConfigurationEdit]) async throws -> PreparedWidgetMove? {
        let editing = configurationEditing
        let widgets = configuration!.widgets
        let generation = configurationWatcher.generation
        return try await Task.detached(priority: .userInitiated) { () throws -> PreparedWidgetMove? in
            try editing.requireSavedWidget(id, widgets: widgets)
            guard !edits.isEmpty else { return nil }
            let before = try Data(contentsOf: editing.configurationURL)
            let after = try editing.customizationData(edits, editing: before)
            let (configuration, loader) = try editing.configurationReplayingSession(over: after)
            return PreparedWidgetMove(before: before, after: after, configuration: configuration, loader: loader, generation: generation)
        }.value
    }

    func writeWidgetMove(_ prepared: PreparedWidgetMove) throws {
        guard configurationWatcher.generation == prepared.generation else {
            throw CommandFailure(message: "The configuration changed. Try your move again.")
        }
        try writeCustomization(prepared.after, replacing: prepared.before, configuration: prepared.configuration, loader: prepared.loader)
    }

    func applyEdits(_ edits: [ConfigurationEdit], persist: Bool) throws {
        flushCustomization()
        let allEdits = sessionEdits + edits
        let root = try editedDocument(edits)
        let data = try configurationData(root)
        var loader = configurationLoader
        let next = try loader.load(configurationURL, data: data, context: context)
        if persist {
            try writeConfiguration(configurationData(root, editing: Data(contentsOf: configurationURL), savedBy: release), to: configurationURL)
        }
        sessionEdits = persist ? [] : allEdits
        configurationLoader = loader
        apply(next)
        configurationWatcher.watch(loader.dependencies)
    }

    func setSessionEdits(_ edits: [ConfigurationEdit]) throws {
        let previous = sessionEdits
        sessionEdits = edits
        do { try applyEdits([], persist: false) }
        catch { sessionEdits = previous; throw error }
    }

    /// The setups with their own bar, from the files beside the main configuration.
    var screenSetupsWithOwnBars: [ScreenSetup] {
        (try? ownBarSetups()) ?? []
    }

    private func ownBarSetups() throws -> [ScreenSetup] {
        let names = try FileManager.default.contentsOfDirectory(atPath: sharedConfigurationURL.deletingLastPathComponent().path)
        return names.sorted().compactMap(ScreenSetup.init(fileName:))
    }

    func ownBarURL(for setup: ScreenSetup) -> URL {
        sharedConfigurationURL.deletingLastPathComponent().appending(path: setup.fileName)
    }

    /// Select the bar before launch can open Settings or setup, without starting its sources yet.
    func prepareScreenSetup(_ setup: ScreenSetup) {
        screenSetup = setup
        configurationURL = barURL(for: setup)
    }

    private func barURL(for setup: ScreenSetup) -> URL {
        FileManager.default.fileExists(atPath: ownBarURL(for: setup).path) ? ownBarURL(for: setup) : sharedConfigurationURL
    }

    /// The setups Customize can edit: the connected one, each connected kind of screen on its own, and those with their own bar.
    func screenSetupsToEdit(connected displays: [BarDisplay]) -> [ScreenSetup] {
        let alone = ScreenKind.allCases.map { kind in ScreenSetup(displays.filter { ScreenKind($0) == kind }) }
        var setups: [ScreenSetup] = []
        for setup in [ScreenSetup(displays)] + alone + screenSetupsWithOwnBars where !setup.kinds.isEmpty && !setups.contains(setup) {
            setups.append(setup)
        }
        return setups
    }

    /// Shows the bar of a setup: the connected one, or one Customize previews. It uses its own bar, or the shared one.
    func showScreenSetup(_ setup: ScreenSetup) {
        screenSetup = setup
        showBar(at: barURL(for: setup))
    }

    /// Copies a bar, the shared one unless given, into the current setup's own file, which the bar then shows and Customize edits.
    func giveScreenSetupItsOwnBar(copying source: URL? = nil) throws {
        guard let screenSetup else { return }
        flushCustomization()
        try FileManager.default.copyItem(at: source ?? sharedConfigurationURL, to: ownBarURL(for: screenSetup))
        showBar(at: ownBarURL(for: screenSetup))
    }

    /// Moves a setup's own bar to the Trash, so that setup uses the shared bar again.
    func useSharedBar(for setup: ScreenSetup) throws {
        if setup == screenSetup { showBar(at: sharedConfigurationURL) }
        try FileManager.default.trashItem(at: ownBarURL(for: setup), resultingItemURL: nil)
    }

    /// A loader for another file or a preview, reading as this bar does.
    private func newLoader() -> ConfigurationLoader {
        var loader = ConfigurationLoader()
        loader.themesDirectory = themesDirectory
        loader.appVersion = release
        return loader
    }

    func otherBars(applying edits: [ConfigurationEdit]) throws -> [(url: URL, before: Data, after: Data)] {
        var otherBars: [(url: URL, before: Data, after: Data)] = []
        for url in [sharedConfigurationURL] + screenSetupsWithOwnBars.map(ownBarURL(for:)) where url != configurationURL {
            let original = try Data(contentsOf: url)
            var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: original)
            var ids: [String] = []
            for edit in edits { root = try edit.applying(to: root, widgetIDs: &ids) }
            var other = newLoader()
            _ = try other.load(url, data: configurationData(root), context: context)
            let data = try configurationData(root, editing: original, savedBy: release)
            if data != original { otherBars.append((url, original, data)) }
        }
        return otherBars
    }

    private func showBar(at url: URL) {
        guard url != configurationURL else { return }
        flushCustomization()
        sessionEdits = []
        customizationHistory.reset()
        configurationLoader.previewProfile = nil
        configurationURL = url
        readConfiguration(leavingEditMode: false)
    }

    var profileFiles: [String: Set<String>] { configurationLoader.profileFiles }

    func customizationProfiles(includingPending: Bool = true) throws -> [ConfigurationProfile] {
        let root = try editedDocument([], replaying: includingPending ? customizationEdits : [])
        var loader = configurationLoader
        _ = try loader.load(configurationURL, data: configurationData(root), context: context)
        return loader.profiles
    }

    func customizationData(_ edits: [ConfigurationEdit], editing original: Data) throws -> Data {
        try configurationEditing.customizationData(edits, editing: original)
    }

    func setCustomizationEdits(_ edits: [ConfigurationEdit]) throws {
        let original = try Data(contentsOf: configurationURL)
        let data = try customizationData(edits, editing: original)
        let (next, loader) = try configurationReplayingSession(over: data)
        if customizationEdits.isEmpty { customizationBase = try configurationReplayingSession(over: original) }
        customizationEdits = edits
        configurationLoader = loader
        apply(next)
        customizationPreview = (data, next, loader)
        configurationWatcher.watch(loader.dependencies)
    }

    func discardCustomizationEdits() {
        customizationEdits = []
        let base = customizationBase
        customizationBase = nil
        readConfiguration(leavingEditMode: false)
        if let error = configurationError, let (next, loader) = base {
            configurationLoader = loader
            apply(next)
            configurationError = error
            configurationWatcher.watch(loader.dependencies)
        }
    }

    func writeCustomization(_ data: Data, replacing original: Data) throws {
        let (next, loader) = if let customizationPreview, customizationPreview.data == data {
            (customizationPreview.configuration, customizationPreview.loader)
        } else {
            try configurationReplayingSession(over: data)
        }
        try writeCustomization(data, replacing: original, configuration: next, loader: loader)
    }

    private func writeCustomization(_ data: Data, replacing original: Data, configuration next: Configuration, loader: ConfigurationLoader) throws {
        guard try Data(contentsOf: configurationURL) == original else {
            throw CommandFailure(message: "The configuration file changed. Try your change again.")
        }
        try writeConfiguration(data, to: configurationURL)
        customizationEdits = []
        customizationBase = nil
        customizationPreview = nil
        configurationLoader = loader
        apply(next)
        configurationWatcher.watch(loader.dependencies)
    }

    func validateCustomization(_ data: Data) throws {
        var loader = configurationLoader
        _ = try loader.load(configurationURL, data: data, context: context)
    }

    private func configurationReplayingSession(over data: Data) throws -> (Configuration, ConfigurationLoader) {
        try configurationEditing.configurationReplayingSession(over: data)
    }

    @discardableResult
    func flushCustomization() -> Bool {
        do {
            try customizationHistory.flush()
            return true
        } catch {
            customizationHistory.error = errorMessage(error)
            return false
        }
    }

    private func removingPackage(_ manifest: WidgetPackageManifest, from document: [String: ConfigurationValue]) throws -> [ConfigurationEdit] {
        let key = "\(manifest.id)/\(manifest.version)"
        var selections = try document["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        if let theme = document["theme"] { selections.append(try theme.decoded(WidgetPackageSelection.self)) }
        var edits: [ConfigurationEdit] = []
        if let selection = selections.first(where: { $0.key == key }) {
            edits.append(ConfigurationEdit(action: manifest.kind == .theme ? .theme : .package, properties: [
                "id": .string(manifest.id), "version": .string(manifest.version), "enabled": .bool(false), "settings": .object(selection.settings)
            ]))
        }
        let screens = try document["screens"]?.decoded([String: [String: ConfigurationValue]].self) ?? [:]
        let screenThemes = try screens.filter { try $0.value["theme"]?.decoded(WidgetPackageSelection.self).key == key }
        if !screenThemes.isEmpty {
            edits.append(ConfigurationEdit(action: .unset, properties: [
                "screens": .object(screenThemes.mapValues { _ in .object(["theme": .null]) })
            ]))
        }
        return edits
    }

    func uninstallPackage(id: String, version: String, fromCustomization: Bool = false) throws {
        let packages = WidgetPackageStore(directory: configurationURL.deletingLastPathComponent().appending(path: "packages"))
        let directory = try packages.directory(id: id, version: version)
        let manifest = try packages.manifest(at: directory)
        var otherBars: [(url: URL, data: Data)] = []
        let urls = [sharedConfigurationURL] + screenSetupsWithOwnBars.map(ownBarURL(for:))
        for url in urls where url != configurationURL {
            var other = newLoader()
            let edits = try removingPackage(manifest, from: other.compose(url, context: context))
            if edits.isEmpty { continue }
            let original = try Data(contentsOf: url)
            var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: original)
            var ids: [String] = []
            for edit in edits { root = try applying(edit, to: root, widgetIDs: &ids, widgetPackageIDs: other.widgetPackageIDs) }
            _ = try other.load(url, data: configurationData(root), context: context)
            otherBars.append((url, try configurationData(root, editing: original, savedBy: release)))
        }
        var loader = ConfigurationLoader()
        loader.appVersion = release
        flushCustomization()
        let document = try loader.compose(configurationURL, data: configurationData(
            editedDocument([], replaying: fromCustomization ? [] : sessionEdits)), context: context)
        let edits = try removingPackage(manifest, from: document)
        if fromCustomization {
            let data = try customizationData(edits, editing: Data(contentsOf: configurationURL))
            let (_, preview) = try configurationReplayingSession(over: data)
            var active = try preview.document["packages"]?.decoded([WidgetPackageSelection].self) ?? []
            if let theme = preview.document["theme"] { active.append(try theme.decoded(WidgetPackageSelection.self)) }
            guard !active.contains(where: { $0.id == id && $0.version == version && $0.enabled }) else {
                throw CommandFailure(message: "Save or discard command-line changes before uninstalling this version.")
            }
            for edit in edits { try customizationHistory.change(edit) }
        } else {
            try applyEdits(edits, persist: true)
        }
        for (url, data) in otherBars { try writeConfiguration(data, to: url) }
        try FileManager.default.removeItem(at: directory)
        try packages.releaseVersion(id: id, version: version)
        if fromCustomization { customizationHistory.dropUnavailableHistory() }
    }

    private func apply(_ next: Configuration) {
        normalComposition = (next, configurationLoader)
        if let triedTheme {
            do {
                let (preview, loader) = try configurationTryingTheme(triedTheme.choice, edits: triedTheme.edits)
                display(preview, loader: loader)
            } catch { configurationError = errorMessage(error) }
        } else {
            display(next, loader: configurationLoader)
        }
    }

    var selectedThemeKey: String {
        let selection = try? effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
        return selection.flatMap { $0.enabled ? $0.key : nil } ?? "built-in"
    }

    var themeTrialDirectory: URL? { triedTheme?.choice.directory }

    func themeSettings(for choice: ThemeChoice, in previewDocument: [String: ConfigurationValue]? = nil) throws -> [String: ConfigurationValue] {
        // Saving uses only the main file's own settings; previews can supply the temporary composition.
        let document = try previewDocument ?? editedMainDocument(replaying: customizationEdits)
        let selection = try document["theme"]?.decoded(WidgetPackageSelection.self)
        return selection.flatMap { $0.key == choice.key ? $0.settings : nil } ?? [:]
    }

    func themeEdit(for choice: ThemeChoice) throws -> ConfigurationEdit {
        var inheritedRoot = try editedMainDocument(replaying: [])
        inheritedRoot["theme"] = nil
        var loader = newLoader()
        let document = try loader.compose(configurationURL, data: configurationData(inheritedRoot), context: context)
        let inherited = try document["theme"]?.decoded(WidgetPackageSelection.self)
        var edit = choice.edit
        if choice.isBuiltIn {
            if inherited?.enabled == true { edit.properties = choice.selection }
        } else {
            let settings = try themeSettings(for: choice)
            if !settings.isEmpty { edit.properties?["settings"] = .object(settings) }
        }
        if edit.properties != nil {
            if choice.isBundled, inherited?.version != nil { edit.properties?["version"] = .null }
            if edit.properties?["settings"] == nil, inherited?.settings.isEmpty == false {
                edit.properties?["settings"] = .null
            }
        }
        return edit
    }

    func applyTheme(_ choice: ThemeChoice, on kind: ScreenKind? = nil, everyBar: Bool = false) throws {
        pendingLinks.theme?.noteThemeChoice()
        try customizationHistory.change(themeEdits(for: choice, on: kind), everyBar: everyBar)
    }

    /// The edits that select `choice` for every screen, or for screens of `kind` only.
    func themeEdits(for choice: ThemeChoice, on kind: ScreenKind?) throws -> [ConfigurationEdit] {
        guard let kind else { return [try themeEdit(for: choice)] }
        return [
            ConfigurationEdit(action: .unset, properties: ["screens": .object([kind.rawValue: .object(["theme": .null])])]),
            ConfigurationEdit(action: .screens, properties: [kind.rawValue: .object(["theme": .object(choice.selection)])])
        ]
    }

    var clearanceConfiguration: Configuration? {
        if let hold = windowClearance.hold { return hold.configuration }
        return normalComposition?.configuration ?? configuration
    }

    /// Shows `choice` on the bar until the trial ends, with `edits` applied over the saved configuration.
    func tryTheme(_ choice: ThemeChoice, edits: [ConfigurationEdit] = []) throws {
        guard normalComposition != nil else {
            throw CommandFailure(message: "Load a bar before trying themes.")
        }
        pendingLinks.theme?.noteThemeChoice()
        let (next, loader) = try configurationTryingTheme(choice, edits: edits)
        triedTheme = (choice, edits)
        display(next, loader: loader)
    }

    func endThemeTrial() {
        guard triedTheme != nil else { return }
        triedTheme = nil
        if let normalComposition { display(normalComposition.configuration, loader: normalComposition.loader) }
    }

    private func configurationTryingTheme(_ choice: ThemeChoice, edits: [ConfigurationEdit]) throws -> (Configuration, ConfigurationLoader) {
        var loader = newLoader()
        let settings = try themeSettings(for: choice, in: configurationLoader.document)
        let layer = try loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: settings)
        let next = try loader.load(configurationURL, data: configurationData(editedMainDocument(replaying: customizationEdits + sessionEdits + edits)),
                                   context: context, previewTheme: PreviewTheme(id: choice.manifest.id, layer: layer))
        return (next, loader)
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
        configurationLoader = loader
        self.context = context
        screenSetup = setup
        adopt(loader)
        configuration = next
        effectiveDocument = loader.document
        origins = loader.origins
        activeProfiles = loader.activeProfiles
        screenDocuments = loader.screenDocuments
        barPresentation.preparePresentations()
    }

    private func display(_ next: Configuration, loader: ConfigurationLoader) {
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
        let sources = packageSources.filter { !$0.isStore }
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
                                                        "configuration": .string(sharedConfigurationURL.path)]) { $1 })
        case .quit:
            // Terminating right away would exit before the command gets its reply.
            Task { NSApp.terminate(nil) }
        case .customize:
            if let id = request.id { onWindowRequest?(.customizeItem(.widget(id))) }
            else { onWindowRequest?(.customize) }
        case .reload:
            barEditing.end()
            try applyEdits([], persist: false)
        case .batch: try applyEdits(request.edits ?? [], persist: request.persist)
        case .uninstallPackage:
            guard let id = request.id, let version = request.version else {
                throw CommandFailure(message: "Uninstall requires a package id and version.")
            }
            try uninstallPackage(id: id, version: version)
        case .reset: try setSessionEdits([])
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
                        "sessionEdits": .number(Double(sessionEdits.count)),
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
        NSWorkspace.shared.open(configurationURL)
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
        endThemeTrial()
        pendingLinks.theme?.discard()
        pendingLinks.theme = nil
        pendingLinks.bar?.discard()
        pendingLinks.bar = nil
        flushCustomization()
        managesConnections = false
        popup.closeAll()
        windowClearance.stop()
        menuBarDelay.stop()
        menuBarAppObservation = nil
        appMenu.read(nil)
        appMenu.mirror.references = []
        reloadTask?.cancel()
        configurationWatcher.stop()
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
        await BugReport.gather(configuration: configurationURL, live: liveReport(), path: shellEnvironment.withLock { $0["PATH"] ?? "" })
    }
}
