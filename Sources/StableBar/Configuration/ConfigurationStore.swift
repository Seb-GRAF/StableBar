import AppKit
import Observation

@MainActor @Observable
final class ConfigurationStore {
    weak var store: BarStore?
    /// The main configuration: the shared bar of every screen setup without its own.
    let sharedConfigurationURL: URL
    /// The release this bar runs as, which reads and stamps its files; nil in development builds.
    let release: String?
    /// The file of the bar on the screens: the shared bar, or the current screen setup's own bar.
    private(set) var configurationURL: URL
    var screenSetup: ScreenSetup?
    var sessionEdits: [ConfigurationEdit] = []
    private(set) var customizationEdits: [ConfigurationEdit] = []
    private var customizationBase: (Configuration, ConfigurationLoader)?
    private var customizationPreview: (data: Data, configuration: Configuration, loader: ConfigurationLoader)?
    var themesDirectory: URL? { configurationLoader.themesDirectory }
    /// The Store and the configured private sources. An invalid list leaves only the Store.
    var packageSources: [PackageSource] {
        guard let store else { return [.store] }
        return (try? PackageSource.configured(in: store.effectiveDocument)) ?? [.store]
    }
    var context = ConfigurationContext()
    var configurationLoader = ConfigurationLoader()
    // A trial changes the displayed composition, never the saved or command-line edits.
    private var normalComposition: (configuration: Configuration, loader: ConfigurationLoader)?
    private var triedTheme: (choice: ThemeChoice, edits: [ConfigurationEdit])?
    let configurationWatcher = ConfigurationWatcher()
    private(set) var reloadTask: Task<Void, Never>?

    init(configurationURL: URL, themesDirectory: URL?, release: String?) {
        self.configurationURL = configurationURL
        sharedConfigurationURL = configurationURL
        self.release = release
        configurationLoader.themesDirectory = themesDirectory
        configurationLoader.appVersion = release
        configurationWatcher.onChange = { [weak self] in self?.scheduleReload() }
    }

    func createStarterAndMigrateFiles() throws {
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
        // The colors go first: they skip a file pinned to a release, and the other migrations pin it. The retired themes
        // skip only a file that was already pinned to this release, so its pin is read before any of them.
        let pinned = pinnedRelease(sharedConfigurationURL)
        try migrateEarlierColors(sharedConfigurationURL, savedBy: release)
        try migrateConfigurationFile(sharedConfigurationURL, savedBy: release)
        try migrateStarterAppleLogo(sharedConfigurationURL, savedBy: release)
        try? migrateRetiredThemes(sharedConfigurationURL, pinned: pinned, themes: themesDirectory, storeThemes: storeThemesDirectory,
                                  savedBy: release)
        for url in screenSetupsWithOwnBars.map(ownBarURL(for:)) {
            let pinned = pinnedRelease(url)
            try? migrateEarlierColors(url, savedBy: release)
            try? migrateConfigurationFile(url, savedBy: release)
            try? migrateStarterAppleLogo(url, savedBy: release)
            try? migrateRetiredThemes(url, pinned: pinned, themes: themesDirectory, storeThemes: storeThemesDirectory, savedBy: release)
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
    }

    func refreshContext(_ next: ConfigurationContext? = nil) {
        guard let store else { return }
        let next = next ?? SystemContext.current(checking: store.profiles.filter(\.enabled))
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
        guard let store else { return }
        if leavingEditMode { store.barEditing.end() }
        defer { configurationWatcher.watch(configurationLoader.dependencies) }
        customizationPreview = nil
        store.customizationHistory.checkForExternalChanges()
        do {
            let base = try configurationLoader.load(configurationURL, context: context)
            let next: Configuration
            if !customizationEdits.isEmpty {
                let edits = try store.customizationHistory.pendingEdits()
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
            store.configurationError = errorMessage(error)
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
        guard let store else { return }
        try configurationEditing.requireSavedWidget(id, widgets: store.configuration?.widgets ?? [])
    }

    struct PreparedWidgetMove: Sendable {
        let before: Data
        let after: Data
        let configuration: Configuration
        let loader: ConfigurationLoader
        let generation: Int
    }

    func prepareWidgetMove(_ id: String, edits: [ConfigurationEdit]) async throws -> PreparedWidgetMove? {
        guard let store else { return nil }
        let editing = configurationEditing
        let widgets = store.configuration!.widgets
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

    private func pinnedRelease(_ url: URL) -> String? {
        let document = try? JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
        return ConfigurationSchema.release(document?["$schema"])
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
        guard let store, url != configurationURL else { return }
        flushCustomization()
        sessionEdits = []
        store.customizationHistory.reset()
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
        guard let store else { return }
        customizationEdits = []
        let base = customizationBase
        customizationBase = nil
        readConfiguration(leavingEditMode: false)
        if let error = store.configurationError, let (next, loader) = base {
            configurationLoader = loader
            apply(next)
            store.configurationError = error
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
        guard let store else { return false }
        do {
            try store.customizationHistory.flush()
            return true
        } catch {
            store.customizationHistory.error = errorMessage(error)
            return false
        }
    }

    private func removingPackage(_ manifest: WidgetPackageManifest, from document: [String: ConfigurationValue]) throws -> [ConfigurationEdit] {
        let key = "\(manifest.id)/\(manifest.version)"
        var selections = try document["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        if let theme = document["theme"] { selections.append(try theme.decoded(WidgetPackageSelection.self)) }
        var edits: [ConfigurationEdit] = []
        if let selection = selections.first(where: { $0.key == key }) {
            edits.append(manifest.kind == .theme ? try firstIncludedThemeEdit() : ConfigurationEdit(action: .package, properties: [
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
        guard let store else { return }
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
            for edit in edits { try store.customizationHistory.change(edit) }
        } else {
            try applyEdits(edits, persist: true)
        }
        for (url, data) in otherBars { try writeConfiguration(data, to: url) }
        try FileManager.default.removeItem(at: directory)
        try packages.releaseVersion(id: id, version: version)
        if fromCustomization { store.customizationHistory.dropUnavailableHistory() }
    }

    private func apply(_ next: Configuration) {
        guard let store else { return }
        normalComposition = (next, configurationLoader)
        if let triedTheme {
            do {
                let (preview, loader) = try configurationTryingTheme(triedTheme.choice, edits: triedTheme.edits)
                store.display(preview, loader: loader)
            } catch { store.configurationError = errorMessage(error) }
        } else {
            store.display(next, loader: configurationLoader)
        }
    }

    var selectedThemeKey: String {
        guard let store else { return "built-in" }
        let selection = try? store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
        return selection.flatMap { $0.enabled ? $0.key : nil } ?? "built-in"
    }

    var themeTrialDirectory: URL? { triedTheme?.choice.directory }

    func themeSettings(for choice: ThemeChoice, in previewDocument: [String: ConfigurationValue]? = nil) throws -> [String: ConfigurationValue] {
        // Saving uses only the main file's own settings; previews can supply the temporary composition.
        let document = try previewDocument ?? editedMainDocument(replaying: customizationEdits)
        let selection = try document["theme"]?.decoded(WidgetPackageSelection.self)
        return selection.flatMap { $0.key == choice.key ? $0.settings : nil } ?? [:]
    }

    func firstIncludedThemeEdit() throws -> ConfigurationEdit {
        guard let themesDirectory else { throw WidgetPackageError.unknownTheme(includedThemeIDs[0]) }
        let directory = themesDirectory.appending(path: includedThemeIDs[0])
        let manifest = try WidgetPackageStore(directory: themesDirectory).manifest(at: directory)
        return try themeEdit(for: ThemeChoice(manifest: manifest, directory: directory, isBundled: true))
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
        guard let store else { return }
        store.pendingLinks.theme?.noteThemeChoice()
        try store.customizationHistory.change(themeEdits(for: choice, on: kind), everyBar: everyBar)
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
        guard let store else { return nil }
        if let hold = store.windowClearance.hold { return hold.configuration }
        return normalComposition?.configuration ?? store.configuration
    }

    /// Shows `choice` on the bar until the trial ends, with `edits` applied over the saved configuration.
    func tryTheme(_ choice: ThemeChoice, edits: [ConfigurationEdit] = []) throws {
        guard let store else { return }
        guard normalComposition != nil else {
            throw CommandFailure(message: "Load a bar before trying themes.")
        }
        store.pendingLinks.theme?.noteThemeChoice()
        let (next, loader) = try configurationTryingTheme(choice, edits: edits)
        triedTheme = (choice, edits)
        store.display(next, loader: loader)
    }

    func endThemeTrial() {
        guard let store, triedTheme != nil else { return }
        triedTheme = nil
        if let normalComposition { store.display(normalComposition.configuration, loader: normalComposition.loader) }
    }

    private func configurationTryingTheme(_ choice: ThemeChoice, edits: [ConfigurationEdit]) throws -> (Configuration, ConfigurationLoader) {
        var loader = newLoader()
        let settings = try themeSettings(for: choice, in: configurationLoader.document)
        let layer = try loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: settings)
        let next = try loader.load(configurationURL, data: configurationData(editedMainDocument(replaying: customizationEdits + sessionEdits + edits)),
                                   context: context, previewTheme: PreviewTheme(id: choice.manifest.id, layer: layer))
        return (next, loader)
    }
}
