import AppKit
import Observation

@MainActor @Observable
final class BarStore: NSObject {
    var configuration: Configuration?
    var configurationError: String?
    var actionErrors: [String: String] = [:]
    var activeApp = NSWorkspace.shared.frontmostApplication
    var activeDisplayID = 1
    var scripts: [String: ScriptWidget] = [:]
    let workspaceStore: WorkspaceStore
    let windowClearance = WindowClearance()
    let appMenu = AppMenu()
    let popup: WidgetPopup
    var update: AppUpdate?
    /// The main configuration: the shared bar of every screen setup without its own.
    let sharedConfigurationURL: URL
    /// The file of the bar on the screens: the shared bar, or the current screen setup's own bar.
    private(set) var configurationURL: URL
    private(set) var screenSetup: ScreenSetup?
    let registry: DataSourceRegistry
    var onConfigurationChange: (() -> Void)?
    var onCustomize: (() -> Void)?
    var onCustomizeWidget: ((String) -> Void)?
    var onCustomizePackages: (() -> Void)?
    var onCustomizeProfile: ((String) -> Void)?
    var onEndCustomizationEditing: (() -> Void)?
    var onTryThemes: ((Int) -> Void)?
    var onEndThemeTrial: (() -> Void)?
    var effectiveDocument: [String: ConfigurationValue] = [:]
    var screenDocuments: [String: [String: ConfigurationValue]] = [:]
    var origins: [String: ConfigurationOrigin] = [:]
    var contributions: [String: [ConfigurationContribution]] = [:]
    var widgetPackageNames: [String: String] = [:]
    var widgetPackageIDs: [String: String] = [:]
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
    @ObservationIgnored lazy var packageStoreClient = PackageStoreClient(
        packages: WidgetPackageStore(directory: configurationURL.deletingLastPathComponent().appending(path: "packages")))
    @ObservationIgnored lazy var packageLibrary = PackageLibrary(store: self)
    var themesDirectory: URL? { configurationLoader.themesDirectory }
    var context = ConfigurationContext()
    private(set) var presentations: [String: WidgetPresentation] = [:]
    private(set) var barStyle = WidgetStyle()
    private(set) var screenBarStyles: [String: WidgetStyle] = [:]
    private(set) var providers: [String: ScriptWidget] = [:]
    private var visibleWidgets: [Int: Set<String>] = [:]
    private var sleeping = false
    private var popupWidgetID: String?
    private(set) var inspectedWidgetID: String?
    private var inspectorOpen = false
    private var configurationLoader = ConfigurationLoader()
    // A trial changes the displayed composition, never the saved or command-line edits.
    private var normalComposition: (configuration: Configuration, loader: ConfigurationLoader)?
    private var triedTheme: ThemeChoice?
    private var managesConnections = false
    private let configurationWatcher = ConfigurationWatcher()
    private(set) var reloadTask: Task<Void, Never>?
    private var eventObservers: [NSObjectProtocol] = []
    private var reloadObserver: NSObjectProtocol?
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var actionTails: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(configurationURL: URL = LaunchCommand.configurationURL, registry: DataSourceRegistry = .builtIn,
         popup: WidgetPopup = WidgetPopup(), themesDirectory: URL? = bundledThemesDirectory,
         customizationSaveDelay: Duration = .milliseconds(500)) {
        self.configurationURL = configurationURL
        sharedConfigurationURL = configurationURL
        self.customizationSaveDelay = customizationSaveDelay
        self.registry = registry
        self.popup = popup
        workspaceStore = WorkspaceStore()
        super.init()
        configurationLoader.themesDirectory = themesDirectory
        configurationWatcher.onChange = { [weak self] in self?.scheduleReload() }
        workspaceStore.onModeChange = { [weak self] mode in
            self?.updatePresentations()
            if self?.managesConnections == true { self?.send(.aerospaceMode, ["INFO": mode ?? ""]) }
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
            send(.workspace, ["INFO": focused?.name ?? "", "SID": String(focused?.monitor ?? activeDisplayID)])
        }
        do {
            let directory = sharedConfigurationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: sharedConfigurationURL.path) {
                let template = Bundle.main.url(forResource: "config", withExtension: "json")!
                try writeConfiguration(Data(contentsOf: template), to: sharedConfigurationURL)
            }
            try migrateConfigurationFile(sharedConfigurationURL)
            if !UserDefaults.standard.bool(forKey: "migratedEarlierColors") {
                try migrateEarlierColors(sharedConfigurationURL)
                UserDefaults.standard.set(true, forKey: "migratedEarlierColors")
            }
            if let setup {
                screenSetup = setup
                configurationURL = barURL(for: setup)
            }
            reloadConfiguration()
            packageLibrary.startUpdateChecks()
        } catch {
            configurationError = errorMessage(error)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateActiveApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppMenu), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshAppMenu), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func updateActiveApp() {
        activeApp = NSWorkspace.shared.frontmostApplication
        if let screen = NSScreen.main { activeDisplayID = BarDisplay(screen: screen).id }
        popup.close()
        refreshContext()
        readAppMenu()
        send(.frontApp, ["INFO": activeApp?.localizedName ?? "Desktop"])
    }

    private func readAppMenu() {
        let shown = configuration?.widgets.contains { widget in
            switch widget.content {
            case .appMenu, .appleMenu: widget.enabled
            default: false
            }
        } == true
        appMenu.read(shown ? activeApp : nil)
    }

    @objc private func refreshAppMenu() {
        activeApp = NSWorkspace.shared.frontmostApplication
        readAppMenu()
    }

    func refreshContext(_ next: ConfigurationContext = SystemContext.current()) {
        var nextWithSameApp = next
        nextWithSameApp.app = context.app
        let reload = nextWithSameApp != context || (next.app != context.app && configurationLoader.matchesApps)
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

    func editedDocument(_ edits: [ConfigurationEdit], data: Data? = nil, replaying: [ConfigurationEdit]? = nil) throws -> [String: ConfigurationValue] {
        var root = try editedMainDocument(data: data, replaying: replaying)
        var loader = configurationLoader
        var ids = try widgetIDs(in: root, loader: &loader)
        for edit in edits {
            try edit.validateTargets(in: ids)
            root = try applying(edit, to: root, widgetIDs: &ids, widgetPackageIDs: loader.widgetPackageIDs)
            if edit.action == .profile || edit.action == .profiles || edit.action == .package {
                ids = try widgetIDs(in: root, loader: &loader)
            }
        }
        return root
    }

    private func widgetIDs(in root: [String: ConfigurationValue], loader: inout ConfigurationLoader) throws -> [String] {
        try loader.compose(configurationURL, data: configurationData(root), context: context)["widgets"]!
            .decoded([[String: ConfigurationValue]].self).map { try $0["id"]!.decoded(String.self) }
    }

    private func applying(_ edit: ConfigurationEdit, to root: [String: ConfigurationValue], widgetIDs: inout [String],
                          widgetPackageIDs: [String: String]) throws -> [String: ConfigurationValue] {
        var root = root
        if edit.action == .package, edit.properties?["enabled"] == .bool(false) {
            for (widget, package) in widgetPackageIDs where edit.properties?["id"] == .string(package) {
                root = try removingReferences(to: widget, in: root)
            }
        }
        return try edit.applying(to: root, widgetIDs: &widgetIDs)
    }

    func editedMainDocument(data: Data? = nil, replaying: [ConfigurationEdit]? = nil) throws -> [String: ConfigurationValue] {
        let data = try data ?? Data(contentsOf: configurationURL)
        var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        var ids: [String] = []
        for edit in replaying ?? (customizationEdits + sessionEdits) { root = try edit.applying(to: root, widgetIDs: &ids) }
        return root
    }

    func applyEdits(_ edits: [ConfigurationEdit], persist: Bool) throws {
        flushCustomization()
        let allEdits = sessionEdits + edits
        let root = try editedDocument(edits)
        let data = try configurationData(root)
        var loader = configurationLoader
        let next = try loader.load(configurationURL, data: data, context: context)
        if persist { try writeConfiguration(configurationData(root, editing: Data(contentsOf: configurationURL)), to: configurationURL) }
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
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sharedConfigurationURL.deletingLastPathComponent().path)) ?? []
        return names.sorted().compactMap(ScreenSetup.init(fileName:))
    }

    func ownBarURL(for setup: ScreenSetup) -> URL {
        sharedConfigurationURL.deletingLastPathComponent().appending(path: setup.fileName)
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

    func otherBars(applying edits: [ConfigurationEdit]) throws -> [(url: URL, before: Data, after: Data)] {
        var otherBars: [(url: URL, before: Data, after: Data)] = []
        for url in [sharedConfigurationURL] + screenSetupsWithOwnBars.map(ownBarURL(for:)) where url != configurationURL {
            let original = try Data(contentsOf: url)
            var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: original)
            var ids: [String] = []
            for edit in edits { root = try edit.applying(to: root, widgetIDs: &ids) }
            var other = ConfigurationLoader()
            other.themesDirectory = themesDirectory
            _ = try other.load(url, data: configurationData(root), context: context)
            let data = try configurationData(root, editing: original)
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

    func customizationProfiles(includingPending: Bool = true) throws -> [ConfigurationProfile] {
        let root = try editedDocument([], replaying: includingPending ? customizationEdits : [])
        var loader = configurationLoader
        _ = try loader.load(configurationURL, data: configurationData(root), context: context)
        return loader.profiles
    }

    func customizationData(_ edits: [ConfigurationEdit], editing original: Data) throws -> Data {
        var edits = edits
        if !sessionEdits.isEmpty {
            var loader = configurationLoader
            let savedIDs = try loader.load(configurationURL, data: original, context: context).widgets.map(\.id)
            let temporaryIDs = Set(try configurationReplayingSession(over: original).0.widgets.map(\.id)).subtracting(savedIDs)
            for index in edits.indices {
                if edits[index].action == .reorder {
                    edits[index].ids = edits[index].ids?.filter { !temporaryIDs.contains($0) }
                } else if [.set, .remove, .unset].contains(edits[index].action),
                          let id = edits[index].id, temporaryIDs.contains(id) {
                    throw CommandFailure(message: "Save or discard command-line changes before editing this widget.")
                }
            }
        }
        let root = try editedDocument(edits, data: original, replaying: [])
        return try configurationData(root, editing: original)
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
        var loader = configurationLoader
        let saved = try loader.load(configurationURL, data: data, context: context)
        if sessionEdits.isEmpty { return (saved, loader) }
        let root = try editedMainDocument(data: data, replaying: sessionEdits)
        let next = try loader.load(configurationURL, data: configurationData(root), context: context)
        return (next, loader)
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
            var other = ConfigurationLoader()
            other.themesDirectory = themesDirectory
            let edits = try removingPackage(manifest, from: other.compose(url, context: context))
            if edits.isEmpty { continue }
            let original = try Data(contentsOf: url)
            var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: original)
            var ids: [String] = []
            for edit in edits { root = try applying(edit, to: root, widgetIDs: &ids, widgetPackageIDs: other.widgetPackageIDs) }
            _ = try other.load(url, data: configurationData(root), context: context)
            otherBars.append((url, try configurationData(root, editing: original)))
        }
        var loader = ConfigurationLoader()
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
        if fromCustomization { customizationHistory.dropUnavailableHistory() }
    }

    private func apply(_ next: Configuration) {
        normalComposition = (next, configurationLoader)
        if let triedTheme {
            do {
                let (preview, loader) = try configurationTryingTheme(triedTheme)
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

    func themeSettings(for choice: ThemeChoice, in previewDocument: [String: ConfigurationValue]? = nil) throws -> [String: ConfigurationValue] {
        // Saving uses only the main file's own settings; previews can supply the temporary composition.
        let document = try previewDocument ?? editedMainDocument(replaying: customizationEdits)
        let selection = try document["theme"]?.decoded(WidgetPackageSelection.self)
        return selection.flatMap { $0.key == choice.key ? $0.settings : nil } ?? [:]
    }

    func themeEdit(for choice: ThemeChoice) throws -> ConfigurationEdit {
        var inheritedRoot = try editedMainDocument(replaying: [])
        inheritedRoot["theme"] = nil
        var loader = ConfigurationLoader()
        loader.themesDirectory = themesDirectory
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

    var clearanceConfiguration: Configuration? { normalComposition?.configuration ?? configuration }

    func tryTheme(_ choice: ThemeChoice) throws {
        guard normalComposition != nil else {
            throw CommandFailure(message: "Load a bar before trying themes.")
        }
        let (next, loader) = try configurationTryingTheme(choice)
        triedTheme = choice
        display(next, loader: loader)
    }

    func endThemeTrial() {
        guard triedTheme != nil else { return }
        triedTheme = nil
        if let normalComposition { display(normalComposition.configuration, loader: normalComposition.loader) }
    }

    private func configurationTryingTheme(_ choice: ThemeChoice) throws -> (Configuration, ConfigurationLoader) {
        var loader = ConfigurationLoader()
        loader.themesDirectory = themesDirectory
        let settings = try themeSettings(for: choice, in: configurationLoader.document)
        let layer = try loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: settings)
        let next = try loader.load(configurationURL, data: configurationData(editedMainDocument()),
                                   context: context, previewTheme: layer)
        return (next, loader)
    }

    private func display(_ next: Configuration, loader: ConfigurationLoader) {
        profiles = loader.profiles
        pinnedProfile = loader.pinnedProfile
        widgetPackageNames = loader.widgetPackageNames
        widgetPackageIDs = loader.widgetPackageIDs
        contributions = loader.contributions
        if effectiveDocument == loader.document {
            origins = loader.origins
            activeProfiles = loader.activeProfiles
            configurationError = nil
            return
        }
        popup.close()
        let previous = configuration?.widgets ?? []
        for (id, script) in scripts {
            let old = previous.first { $0.id == id }
            let new = next.widgets.first { $0.id == id && $0.enabled }
            if case .provider = old?.content {
                scripts.removeValue(forKey: id)
                continue
            }
            if old?.content != new?.content || old?.timeout != new?.timeout
                || old?.environment != new?.environment || configuration?.environment != next.environment {
                script.stop()
                scripts.removeValue(forKey: id)
            }
        }
        let usedProviders = next.activeProviders
        for (name, script) in providers {
            if !usedProviders.contains(name) || configuration?.providers[name] != next.providers[name]
                || configuration?.environment != next.environment {
                script.stop()
                providers.removeValue(forKey: name)
            }
        }
        for name in usedProviders where providers[name] == nil {
            let script = ScriptWidget()
            let provider = next.providers[name]!
            var environment = next.environment
            environment["NAME"] = name
            environment["CONFIG_DIR"] = configurationURL.deletingLastPathComponent().path
            if let events = registry[provider.type]?.events, !events.isEmpty {
                script.onOutputChange = { [weak self, weak script] previous, output in
                    for event in events {
                        if let variables = event.variables(from: previous, to: output) { self?.send(event, variables, from: script) }
                    }
                }
            }
            script.start(provider: provider, registry: registry, environment: environment)
            providers[name] = script
        }
        for widget in next.widgets where widget.enabled {
            switch widget.content {
            case let .provider(name): scripts[widget.id] = providers[name]
            case let .script(command, interval) where scripts[widget.id] == nil:
                let script = ScriptWidget()
                scripts[widget.id] = script
                script.start(command: command, interval: interval, timeout: widget.timeout,
                             environment: commandEnvironment(widget, configuration: next))
            default: break
            }
        }
        let needsWorkspaces = next.widgets.contains { $0.enabled && ($0.content == .workspaces || $0.display == .active) }
        configuration = next
        managesConnections = true
        readAppMenu()
        preparePresentations()
        effectiveDocument = loader.document
        screenDocuments = loader.screenDocuments
        origins = loader.origins
        activeProfiles = loader.activeProfiles
        configurationError = nil
        let center = DistributedNotificationCenter.default()
        for observer in eventObservers { center.removeObserver(observer) }
        let events = Set(next.widgets.filter(\.enabled).flatMap(\.events) + usedProviders.flatMap { next.providers[$0]!.events }
                         + (needsWorkspaces && next.workspaceSource == .yabai ? [BuiltInEvent.yabai.rawValue] : []))
        eventObservers = events.map { event in
            center.addObserver(forName: Notification.Name(event), object: nil, queue: .main) { [weak self] notification in
                var environment = withoutShellVariables(notification.userInfo as? [String: String] ?? [:])
                if environment["INFO"] == nil, let info = notification.userInfo,
                   let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
                    environment["INFO"] = String(decoding: data, as: UTF8.self)
                }
                MainActor.assumeIsolated { self?.refreshScripts(for: event, environment: environment) }
            }
        }
        updateSuspension()
        onConfigurationChange?()
    }

    /// Keeps one presentation per configured widget and has every running script re-resolve
    /// styles when it updates. A script reports to the first store that prepares it, so a store
    /// that only shows the bar's scripts, like the setup preview, doesn't take them over.
    func preparePresentations() {
        presentations = Dictionary(uniqueKeysWithValues: (configuration?.widgets ?? []).map {
            ($0.id, presentations[$0.id] ?? WidgetPresentation())
        })
        for script in scripts.values where script.onUpdate == nil {
            script.onUpdate = { [weak self] in self?.updatePresentations() }
        }
        updatePresentations()
    }

    /// Resolves every widget's style and presence and the bar's style from the configuration and the
    /// current outputs. Only changed values are assigned, so views of unaffected widgets stay valid.
    func updatePresentations() {
        guard let configuration else { return }
        let output = { (id: String) in self.scripts[id]?.output }
        let overrides = OrderedStyleOverrides(widgets: configuration.widgets, output: output)
        let outputNeedsMode = overrides.bar.usesModeStates || overrides.widgets.values.contains(where: \.usesModeStates)
            || scripts.values.contains { $0.output.style?.usesModeStates == true || $0.output.styles?.values.contains(where: \.usesModeStates) == true }
        if managesConnections {
            workspaceStore.configure(source: configuration.workspaceSource,
                                     workspaces: configuration.widgets.contains { $0.enabled && ($0.content == .workspaces || $0.display == .active) },
                                     mode: configuration.needsModeConnection || outputNeedsMode)
        }
        let mode = modePresentation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screenOverrides = configuration.screenLooks.mapValues { OrderedStyleOverrides(widgets: $0.widgets, output: output) }
        for widget in configuration.widgets {
            let script = scripts[widget.id]
            let base = resolveStyle(widgetStyleLayers(widget, defaults: configuration.defaults, overrides: overrides, own: script?.output,
                                                      role: configuration.roleStyle(widget.role)))
            let usesMode = base.usesModeStates || widget.layout?.usesModeStates(roles: configuration.roles) == true
                || widget.hoverLayout?.usesModeStates(roles: configuration.roles) == true
                || widget.overlay?.usesModeStates(roles: configuration.roles) == true
                || script?.output.styles?.values.contains(where: \.usesModeStates) == true
            let animation = script?.output.animation ?? widget.animation ?? configuration.bar.animation
            let state = dataState(script?.output, rules: widget.rules)
            var screenStyles: [String: ResolvedWidgetStyle] = [:]
            for (kind, look) in configuration.screenLooks {
                guard let own = look.widgets.first(where: { $0.id == widget.id }) else { continue }
                let base = resolveStyle(widgetStyleLayers(own, defaults: look.defaults, overrides: screenOverrides[kind]!, own: script?.output,
                                                          role: look.roleStyle(own.role)))
                screenStyles[kind] = ResolvedWidgetStyle(base: base, state: state,
                                                         mode: usesMode ? modePresentation(on: ScreenKind(rawValue: kind)!) : ModePresentation())
            }
            presentations[widget.id]?.update(style: ResolvedWidgetStyle(base: base, state: state, mode: usesMode ? mode : ModePresentation()),
                                             screenStyles: screenStyles,
                                             hidden: script?.output.hidden == true && script?.error == nil,
                                             display: script?.output.display,
                                             visibility: visibilityAnimation(widget.transition ?? configuration.bar.motion.transition, animation: animation,
                                                                             reduceMotion: reduceMotion))
            presentations[widget.id]?.show(script?.output.temporary, output: script?.outputNumber ?? 0,
                                           animation: reduceMotion ? nil : animation)
        }
        let bar = resolveStyle(barStyleLayers(configuration.bar.style, overrides: overrides), states: StyleStates(mode: mode))
        if barStyle != bar { barStyle = bar }
        let kinds = ScreenKind.allCases.filter { configuration.screenLooks[$0.rawValue] != nil }
        let screenBars = Dictionary(uniqueKeysWithValues: kinds.map { kind in
            (kind.rawValue, resolveStyle(barStyleLayers(configuration.bar(on: kind).style, overrides: overrides),
                                         states: StyleStates(mode: modePresentation(on: kind))))
        })
        if screenBarStyles != screenBars { screenBarStyles = screenBars }
    }

    func barStyle(on kind: ScreenKind) -> WidgetStyle {
        screenBarStyles[kind.rawValue] ?? barStyle
    }

    var modePresentation: ModePresentation {
        ModePresentation(mode: configuration?.workspaceSource == .aerospace ? workspaceStore.mode : nil,
                         aliases: configuration?.modeAliases ?? [:])
    }

    func modePresentation(on kind: ScreenKind) -> ModePresentation {
        ModePresentation(mode: configuration?.workspaceSource == .aerospace ? workspaceStore.mode : nil,
                         aliases: configuration?.look(on: kind).modeAliases ?? [:])
    }

    func setVisibleWidgets(ids: Set<String>, displayID: Int) {
        visibleWidgets[displayID] = ids
        updateSuspension()
    }

    func retainDisplays(_ ids: Set<Int>) {
        visibleWidgets = visibleWidgets.filter { ids.contains($0.key) }
        updateSuspension()
    }

    func setPopupVisibleWidget(_ id: String?, anchor: NSView? = nil) {
        popupWidgetID = id
        let anchor = anchor.map(ObjectIdentifier.init)
        for (widgetID, presentation) in presentations { presentation.setPopupAnchor(widgetID == id ? anchor : nil) }
        updateSuspension()
    }

    func setInspectedWidget(_ id: String?) {
        inspectedWidgetID = id
        updateSuspension()
    }

    func setInspectorOpen(_ open: Bool) {
        inspectorOpen = open
        if !open { inspectedWidgetID = nil }
        updateSuspension()
    }

    func widgetStatus(for widget: WidgetConfiguration) -> WidgetStatus {
        if !widget.enabled { return .disabled }
        if let error = actionErrors[widget.id] { return .failed("Click action: \(error)") }
        let script = scripts[widget.id]
        if let error = script?.error { return .failed(error) }
        if widget.content == .workspaces, let error = workspaceStore.error { return .failed(error) }
        if !widget.content.permissions.isEmpty, !appMenu.isTrusted {
            return .accessNeeded(.accessibility)
        }
        if let name = widget.providerName, let provider = configuration?.providers[name],
           let permission = registry[provider.type]?.permission,
           let access = script?.output.fields?["access"], access != "granted" {
            return .accessNeeded(permission)
        }
        if script?.diagnostics.suspended == true { return .paused }
        if let script {
            if script.diagnostics.lastUpdated == nil { return .starting }
            if let name = widget.providerName, let provider = configuration?.providers[name],
               registry[provider.type]?.continuous == true, script.diagnostics.running {
                return .connected
            }
            if script.diagnostics.running { return .updating }
        }
        return .working
    }

    func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        updateSuspension()
    }

    private func updateSuspension() {
        var visible = visibleWidgets.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        if let popupWidgetID { visible.insert(popupWidgetID) }
        if inspectorOpen, let inspectedWidgetID { visible.insert(inspectedWidgetID) }
        for (name, provider) in providers {
            let definition = configuration?.providers[name]
            let sendsSubscribedEvents = registry[definition?.type ?? ""]?.events
                .contains { configuration?.subscribedEvents.contains($0.rawValue) == true } == true
            let hidden = definition?.whenVisible == true && !sendsSubscribedEvents
                && !(configuration?.widgets.contains { $0.content == .provider(name) && visible.contains($0.id) } ?? false)
            if sleeping || hidden { provider.suspend() } else { provider.resume() }
        }
        for widget in configuration?.widgets ?? [] {
            if case .script = widget.content {
                if sleeping { scripts[widget.id]?.suspend() } else { scripts[widget.id]?.resume() }
            }
        }
    }

    func handle(_ request: RuntimeRequest) throws -> ConfigurationValue {
        switch request.action {
        case .customize:
            if let id = request.id { onCustomizeWidget?(id) }
            else { onCustomize?() }
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
            guard let id = request.id, let script = scripts[id] else { throw CommandFailure(message: "Refresh requires a running widget id.") }
            guard !script.diagnostics.suspended else {
                throw CommandFailure(message: "Widget is suspended. Choose Resume for testing in Status or make a consumer visible before refreshing.")
            }
            script.refresh(ScriptEvent(sender: "manual"))
        case .trigger:
            guard let event = request.id else { throw CommandFailure(message: "Trigger requires an event name.") }
            refreshScripts(for: event, environment: withoutShellVariables(request.environment ?? [:]))
        case .query: break
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
            result["modeStates"] = .array(StyleStates(mode: modePresentation).names.map(ConfigurationValue.string))
            result["modeConnectionError"] = workspaceStore.connectionError.map(ConfigurationValue.string) ?? .null
            if let widget = configuration?.widgets.first(where: { $0.id == id }) {
                let prefixes = ["widgets.\(id)", "defaults", "popupDefaults", "workspaceDefaults", "modeAliases", "roles"]
                    + (widget.popupName.map { ["popups.\($0)"] } ?? [])
                result["origins"] = .object(origins.filter { entry in
                    prefixes.contains { entry.key == $0 || entry.key.hasPrefix($0 + ".") }
                }.mapValues { .string($0.description) })
                result["role"] = widget.role.map { .string($0.rawValue) } ?? .null
                result["resolvedStyle"] = presentations[id]?.style.style(hovered: false).configurationValue ?? .object([:])
                result["presentationLayers"] = .array(presentationLayers(for: widget))
                if widget.content == .workspaces {
                    result["workspacePresentation"] = .object(try configuration!.workspaceDefaults.mergedProperties(definition["workspace"]))
                }
                let shown = label(for: widget)
                result["text"] = .string(shown.text)
                result["icon"] = shown.icon.map(ConfigurationValue.string) ?? .null
                result["fields"] = .object(shown.fields.mapValues(ConfigurationValue.string))
            }
            if let script = scripts[id] {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                result["diagnostics"] = try JSONDecoder().decode(ConfigurationValue.self, from: encoder.encode(script.diagnostics))
                result["samples"] = .array(script.samples.map(ConfigurationValue.number))
                result["latestOutput"] = (try? JSONDecoder().decode(ConfigurationValue.self, from: Data(script.diagnostics.lastStdout.utf8)))
                    ?? .string(script.diagnostics.lastStdout)
                result["error"] = script.error.map(ConfigurationValue.string) ?? .null
                result["values"] = .object((script.output.values ?? [:]).mapValues(ConfigurationValue.number))
                result["state"] = presentations[id]?.style.state.map(ConfigurationValue.string) ?? .null
                result["temporaryFields"] = presentations[id]?.temporaryFields
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
                scripts[widget.id]?.output.barStyle.map { .object(["source": .string("output.\(widget.id).barStyle"),
                                                                 "style": $0.configurationValue]) }
            }
        return .object(["configuration": .object(effectiveDocument),
                        "mode": workspaceStore.mode.map(ConfigurationValue.string) ?? .null,
                        "modeStates": .array(StyleStates(mode: modePresentation).names.map(ConfigurationValue.string)),
                        "modeConnectionError": workspaceStore.connectionError.map(ConfigurationValue.string) ?? .null,
                        "resolvedBarStyle": barStyle.configurationValue,
                        "barPresentationLayers": .array(barLayers),
                        "origins": .object(origins.mapValues { .string($0.description) }),
                        "profiles": .array(activeProfiles.map(ConfigurationValue.string)),
                        "sessionEdits": .number(Double(sessionEdits.count)),
                        "error": configurationError.map(ConfigurationValue.string) ?? .null])
    }

    private func presentationLayers(for widget: WidgetConfiguration) -> [ConfigurationValue] {
        guard let configuration else { return [] }
        func layer(_ source: String, _ style: WidgetStyle) -> ConfigurationValue {
            .object(["source": .string(source), "style": style.configurationValue])
        }
        var layers = [layer("defaults", configuration.defaults)]
        if let role = widget.role { layers.append(layer("roles.\(role.rawValue)", configuration.roleStyle(role))) }
        layers.append(layer("widgets.\(widget.id).style", widget.style))
        for source in configuration.widgets {
            if let style = scripts[source.id]?.output.widgetStyles?[widget.id] {
                layers.append(layer("output.\(source.id).widgetStyles.\(widget.id)", style))
            }
        }
        if let own = scripts[widget.id]?.output {
            if let style = own.style { layers.append(layer("output.\(widget.id).style", style)) }
            if let color = own.color { layers.append(layer("output.\(widget.id).color", WidgetStyle(foreground: color))) }
        }
        return layers
    }

    private func commandEnvironment(_ widget: WidgetConfiguration, configuration: Configuration) -> [String: String] {
        var environment = configuration.environment.merging(widget.environment) { _, widget in widget }
        environment["NAME"] = widget.id
        environment["CONFIG_DIR"] = configurationURL.deletingLastPathComponent().path
        return environment
    }

    /// Sends one of StableBar's own events to the widgets and providers that subscribe to it.
    /// `sender`, the provider whose change sent the event, isn't refreshed: it has the change already,
    /// and a refresh would restart it.
    func send(_ event: BuiltInEvent, _ variables: [String: String] = [:], from sender: ScriptWidget? = nil) {
        refreshScripts(for: event.rawValue, environment: variables, skipping: sender)
    }

    func refreshScripts(for event: String, environment: [String: String] = [:], skipping sender: ScriptWidget? = nil) {
        if event == BuiltInEvent.yabai.rawValue { workspaceStore.trigger() }
        var refreshed = Set<ObjectIdentifier>()
        if let sender { refreshed.insert(ObjectIdentifier(sender)) }
        for widget in configuration?.widgets ?? [] {
            let providerEvents: [String]
            if case let .provider(name) = widget.content { providerEvents = configuration!.providers[name]!.events }
            else { providerEvents = [] }
            if (widget.events + providerEvents).contains(event), let script = scripts[widget.id],
               refreshed.insert(ObjectIdentifier(script)).inserted {
                script.refresh(ScriptEvent(sender: event, environment: environment))
            }
        }
    }

    @discardableResult
    func runAction(_ command: String, widget: WidgetConfiguration,
                   event: ScriptEvent = ScriptEvent(sender: "mouse.clicked")) -> Task<Void, Never> {
        guard barEditing.allowsWidgetActions else { return Task {} }
        let id = UUID()
        let script = scripts[widget.id]
        let environment = commandEnvironment(widget, configuration: configuration!)
        let previous = actionTails[widget.id]?.task
        let task = Task {
            await previous?.value
            defer {
                actions.removeValue(forKey: id)
                if actionTails[widget.id]?.id == id { actionTails.removeValue(forKey: widget.id) }
            }
            do {
                try Task.checkCancellation()
                _ = try await runCommand("/bin/zsh", arguments: ["-c", command],
                                         timeout: widget.timeout, environment: event.commandEnvironment(environment))
                if let script, scripts[widget.id] === script {
                    script.refresh(ScriptEvent(sender: "action", environment: event.environment))
                }
                if actionErrors[widget.id] != nil { actionErrors[widget.id] = nil }
            } catch {
                if Task.isCancelled { return }
                actionErrors[widget.id] = error.localizedDescription
            }
        }
        actions[id] = task
        actionTails[widget.id] = (id, task)
        return task
    }

    func openConfiguration() {
        NSWorkspace.shared.open(configurationURL)
    }

    func stop() {
        packageLibrary.stopUpdateChecks()
        barEditing.end()
        endThemeTrial()
        flushCustomization()
        managesConnections = false
        popup.close()
        windowClearance.stop()
        appMenu.read(nil)
        reloadTask?.cancel()
        configurationWatcher.stop()
        workspaceStore.stop()
        for script in scripts.values { script.stop() }
        for provider in providers.values { provider.stop() }
        providers.removeAll()
        scripts.removeAll()
        for action in actions.values { action.cancel() }
        actions.removeAll()
        actionTails.removeAll()
        for observer in eventObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        if let reloadObserver { DistributedNotificationCenter.default().removeObserver(reloadObserver) }
        reloadObserver = nil
        eventObservers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

private func withoutShellVariables(_ environment: [String: String]) -> [String: String] {
    let shell = shellEnvironment.withLock { $0 }
    return environment.filter { shell[$0.key] == nil }
}

/// One widget's resolved style and presence, observed per widget so one widget's update doesn't
/// invalidate the views of the others.
@MainActor @Observable
final class WidgetPresentation {
    private(set) var style = ResolvedWidgetStyle(base: WidgetStyle())
    private(set) var screenStyles: [String: ResolvedWidgetStyle] = [:]
    /// Displays where hovering expands the widget: an app menu with `expandOnHover`, or the Sound
    /// widget with its volume slider. The bar's measuring copy, which no pointer reaches, reads it.
    var expandedDisplays: Set<Int> = []
    /// Output `hidden`, unless the widget has an error to show.
    private(set) var hidden = false
    /// Output `display`, which replaces the configured one.
    private(set) var display: DisplaySelection?
    /// The view that anchors this widget's open popup: only that instance shows `open`.
    private(set) var popupAnchor: ObjectIdentifier?
    /// Fields from the latest output's `temporary`, shown over the widget's own until they expire.
    private(set) var temporaryFields: [String: String]?
    /// The `temporary` that shows.
    @ObservationIgnored private var temporary: TemporaryOutput?
    /// The number of the last output `show` was given.
    @ObservationIgnored private var shownOutput = 0
    @ObservationIgnored private(set) var expiry: Task<Void, Never>?

    /// Assigns only what changed: equal assignments must not invalidate the widget's views. With a
    /// `visibility` animation, a change of `hidden` animates the widget in or out.
    func update(style: ResolvedWidgetStyle, screenStyles: [String: ResolvedWidgetStyle] = [:], hidden: Bool, display: DisplaySelection?,
                visibility: WidgetAnimation? = nil) {
        if self.style != style { self.style = style }
        if self.screenStyles != screenStyles { self.screenStyles = screenStyles }
        if self.hidden != hidden {
            if let visibility { visibility.animate { self.hidden = hidden } } else { self.hidden = hidden }
        }
        if self.display != display { self.display = display }
    }

    func style(on kind: ScreenKind) -> ResolvedWidgetStyle {
        screenStyles[kind.rawValue] ?? style
    }

    /// Expands or collapses the widget on `display`, with `animation` when given.
    func setExpanded(_ expanded: Bool, on display: Int, animation: WidgetAnimation? = nil) {
        guard expandedDisplays.contains(display) != expanded else { return }
        var displays = expandedDisplays
        if expanded { displays.insert(display) } else { displays.remove(display) }
        if let animation { animation.animate { expandedDisplays = displays } } else { expandedDisplays = displays }
    }

    func setPopupAnchor(_ anchor: ObjectIdentifier?) {
        if popupAnchor != anchor { popupAnchor = anchor }
    }

    /// Shows the `temporary` of a new output for its duration. `output` numbers the output, so the
    /// same output applied again changes nothing. An output without one, or with the same one while
    /// it shows, lets the current one run out. With an `animation`, the fields come and go with it.
    func show(_ next: TemporaryOutput?, output: Int, animation: WidgetAnimation? = nil) {
        guard output != shownOutput else { return }
        shownOutput = output
        guard let next, next != temporary else { return }
        temporary = next
        expiry?.cancel()
        if temporaryFields != next.fields { setTemporaryFields(next.fields, animation: animation) }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.duration))
            guard !Task.isCancelled, let self else { return }
            temporary = nil
            setTemporaryFields(nil, animation: animation)
        }
    }

    private func setTemporaryFields(_ fields: [String: String]?, animation: WidgetAnimation?) {
        if let animation { animation.animate { temporaryFields = fields } } else { temporaryFields = fields }
    }
}
