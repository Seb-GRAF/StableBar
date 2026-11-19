import AppKit
import Observation

@MainActor @Observable
final class BarLinkCandidate {
    enum State: Equatable { case ready, trying, used, failed(String) }
    enum Action { case tryOnBar(ScreenKind?), use(ScreenKind?, everyBar: Bool, configurationURL: URL) }
    /// A widget the link carries, as the card lists it.
    struct Widget: Identifiable, Equatable {
        /// `store` says in plain words what its package does. `unlisted` when the Store doesn't list its package, so
        /// the bar leaves it out.
        enum Source: Equatable { case builtIn, store(summary: String), unlisted }
        let id: String
        let name: String
        let source: Source
    }

    let link: BarLink
    /// The link's look, checked as a theme link and kept in a temporary folder until it's used.
    let look: ThemeLinkCandidate
    let preview: ThemePreview
    /// The fonts the look names that this Mac doesn't have, which the bar shows in the system font.
    let missingFonts: [String]
    private let builtIns: [WidgetConfiguration]
    /// The Store's entry and files for each package the Store lists, once they have loaded.
    private(set) var entries: [(entry: PackageIndex.Entry, inspection: WidgetPackageInspection)]?
    /// The packages the Store's review must show before the bar can be tried or used.
    private(set) var reviews: [WidgetPackageInspection] = []
    /// The widgets Try on Bar and Use this bar leave out.
    var unticked: Set<String> = []
    /// Whether Try on Bar and Use this bar apply the link's look; otherwise the bar keeps its own.
    var appliesLook = true
    /// Tests replace it to stand for a Mac with or without a notched display.
    var hasNotchedDisplay: () -> Bool = { NSScreen.screens.map(BarDisplay.init).contains { $0.notch != nil } }
    private(set) var working = false
    private var installed: [String: (inspection: WidgetPackageInspection, settings: [String: ConfigurationValue])] = [:]
    /// The packages of `installed` that were already on the bar, whose settings are read again each time.
    private var reused: Set<String> = []
    /// What the Store's review goes on with once it adds its packages.
    private(set) var pending: Action?
    /// Each listed Store widget as the preview draws it: a text widget with its package's name and symbol.
    private var placeholders: [String: WidgetConfiguration] = [:]
    private var trialDirectory: URL?
    private var candidateState: State = .ready
    var state: State {
        if candidateState == .trying, store?.configurationStore.themeTrialDirectory != trialDirectory { return .ready }
        return candidateState
    }
    private weak var store: BarStore?
    private var discarded = false

    init(link: BarLink, store: BarStore) throws {
        look = try ThemeLinkCandidate(link: link.theme, store: store, origin: .barLink)
        do {
            preview = try ThemePreview(choice: look.choice, themesDirectory: store.configurationStore.themesDirectory)
            builtIns = try link.widgets.map { try ConfigurationValue.object($0).decoded(WidgetConfiguration.self) }
            let families = NSFontManager.shared.availableFontFamilies
            let values = configurationValues(try JSONDecoder().decode(ConfigurationValue.self, from: link.theme.configuration))
            missingFonts = Set(values.compactMap { path, value in
                // A reference names a token or setting, not a font; a face name such as Menlo-Bold works too.
                guard path.hasSuffix(".fontName"), case let .string(name) = value, name != "system", !name.hasPrefix("@"),
                      !families.contains(name), NSFont(name: name, size: 13) == nil else { return nil }
                return name
            }).sorted()
        } catch {
            look.discard()
            throw error
        }
        self.link = link
        self.store = store
    }

    /// Every widget the link carries, in bar order. Store widgets join once the Store has loaded.
    var widgets: [Widget] {
        link.widgetOrder.compactMap { id in
            if let widget = builtIns.first(where: { $0.id == id }) {
                return Widget(id: id, name: WidgetDisplayName.title(for: widget.content), source: .builtIn)
            }
            guard let entries else { return nil }
            guard let package = entries.first(where: { $0.inspection.widgets.contains { $0.id == id } }) else {
                return Widget(id: id, name: id, source: .unlisted)
            }
            return Widget(id: id, name: package.entry.name, source: .store(summary: Self.summary(of: package.inspection)))
        }
    }

    /// The ticked widgets in bar order, as the card's preview draws them.
    var previewWidgets: [WidgetConfiguration] {
        link.widgetOrder.filter { !unticked.contains($0) }.compactMap { id in builtIns.first { $0.id == id } ?? placeholders[id] }
    }

    /// Whether a widget is ticked, so Try on Bar and Use this bar replace the bar's widgets.
    var replacesWidgets: Bool {
        builtIns.contains { !unticked.contains($0.id) } || !chosenEntries.isEmpty
    }

    /// The Store's packages that a ticked widget comes from.
    private var chosenEntries: [(entry: PackageIndex.Entry, inspection: WidgetPackageInspection)] {
        (entries ?? []).filter { package in
            package.inspection.widgets.contains { link.widgetOrder.contains($0.id) && !unticked.contains($0.id) }
        }
    }

    func loadStore() async {
        guard entries == nil, let store else { return }
        guard !link.packages.isEmpty else {
            entries = []
            return
        }
        let catalog = await store.packageStoreClient.catalog()
        if catalog.errors[PackageSource.storeID] != nil {
            candidateState = .failed("The Store is unavailable, so this bar’s Store widgets can’t be installed. Open the link again later.")
            return
        }
        do {
            var loaded: [(entry: PackageIndex.Entry, inspection: WidgetPackageInspection)] = []
            for package in link.packages {
                guard let entry = catalog.widgets.first(where: { $0.sourceID == PackageSource.storeID && $0.id == package.id }) else { continue }
                let inspection = try await store.packageStoreClient.packageForAdding(entry)
                for widget in inspection.widgets where link.widgetOrder.contains(widget.id) {
                    placeholders[widget.id] = try ConfigurationValue.object([
                        "id": .string(widget.id), "type": .string("text"), "text": .string(entry.name),
                        "icon": entry.symbol.map(ConfigurationValue.string) ?? .null,
                        "position": link.widgetOverrides[widget.id]?["position"] ?? .string(widget.position.rawValue)
                    ]).decoded(WidgetConfiguration.self)
                }
                loaded.append((entry, inspection))
            }
            entries = loaded
        } catch {
            candidateState = .failed(errorMessage(error))
        }
    }

    func tryOnBar(on kind: ScreenKind? = nil) async {
        guard !discarded, !working, entries != nil, state != .used, let store else { return }
        working = true
        defer { working = false }
        do {
            guard try await installPackages(in: store, then: .tryOnBar(kind)), !discarded else { return }
            store.barEditing.end()
            store.onWindowRequest?(.endThemeTrial)
            var choice = look.choice
            if !appliesLook {
                let screens = try store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self) ?? [:]
                let screenTheme = try kind.flatMap { screens[$0.rawValue]?["theme"] }?.decoded(WidgetPackageSelection.self)
                let key = screenTheme.map { $0.enabled ? $0.key : "built-in" } ?? store.configurationStore.selectedThemeKey
                guard let current = ThemeCatalog(packages: store.configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                                 themesDirectory: store.configurationStore.themesDirectory, selectedKey: key).choices.first(where: { $0.key == key }) else {
                    throw CommandFailure(message: "The theme \(key) isn’t installed.")
                }
                choice = current
            }
            try store.configurationStore.tryTheme(choice, edits: edits(in: store, on: kind))
            trialDirectory = choice.directory
            candidateState = .trying
        } catch {
            store.configurationStore.endThemeTrial()
            candidateState = .failed(errorMessage(error))
        }
    }

    func cancelTrial() {
        guard state == .trying else { return }
        if store?.configurationStore.themeTrialDirectory == trialDirectory { store?.configurationStore.endThemeTrial() }
        candidateState = .ready
    }

    /// Replaces the bar's widgets and look with the link's ticked ones, in one change that Undo takes back. A use that
    /// resumes after the Store's review passes the file it started on, and stops if the setup has changed since.
    func use(on kind: ScreenKind? = nil, everyBar: Bool = false, configurationURL: URL? = nil) async {
        guard !discarded, !working, entries != nil, state != .used, let store else { return }
        working = true
        defer { working = false }
        let configurationURL = configurationURL ?? store.configurationStore.configurationURL
        do {
            guard try await installPackages(in: store, then: .use(kind, everyBar: everyBar, configurationURL: configurationURL)) else { return }
            var themeEdits: [ConfigurationEdit] = []
            if appliesLook {
                let theme = try await look.installedTheme(in: store.packageStoreClient.packages)
                themeEdits = try store.configurationStore.themeEdits(for: theme, on: kind)
            }
            guard !discarded, store.configurationStore.configurationURL == configurationURL else { return }
            // The trial's edits don't apply over the saved bar, so it ends first.
            store.onWindowRequest?(.endThemeTrial)
            store.configurationStore.endThemeTrial()
            try store.customizationHistory.change(themeEdits + edits(in: store, on: kind), everyBar: everyBar)
            candidateState = .used
            look.discard()
        } catch {
            guard !discarded else { return }
            if let trialDirectory, store.configurationStore.themeTrialDirectory == trialDirectory {
                store.onWindowRequest?(.endThemeTrial)
                store.configurationStore.endThemeTrial()
            }
            candidateState = .failed(errorMessage(error))
        }
    }

    /// Takes a package the Store's review added, with the settings it shows.
    func reviewed(_ inspection: WidgetPackageInspection, settings: [String: ConfigurationValue]) {
        installed[inspection.manifest.id] = (inspection, settings)
    }

    func cancelReview() {
        reviews = []
        pending = nil
    }

    /// Closes the review and goes on with Try on Bar or Use this bar once the review has added its packages.
    func resume() async {
        let action = pending
        reviews = []
        pending = nil
        switch action {
        case let .tryOnBar(kind)?: await tryOnBar(on: kind)
        case let .use(kind, everyBar, configurationURL)?: await use(on: kind, everyBar: everyBar, configurationURL: configurationURL)
        case nil: break
        }
    }

    func discard() {
        guard !discarded else { return }
        discarded = true
        cancelTrial()
        look.discard()
    }

    /// The link's settings for a package that its manifest accepts; the others keep the package's defaults.
    func settings(for manifest: WidgetPackageManifest) -> [String: ConfigurationValue] {
        let settings = link.packages.first { $0.id == manifest.id }?.settings ?? [:]
        return settings.filter { name, value in
            manifest.settings[name].map { BarLink.carries($0) && $0.accepts(value) } == true
        }
    }

    /// Installs the chosen Store packages that need no review, and takes a Store version already on the bar as it is,
    /// with the link's settings over the bar's: it already runs. False when some need a review: they're then `reviews`,
    /// and `action` goes on once the review adds them.
    private func installPackages(in store: BarStore, then action: Action) async throws -> Bool {
        let packages = store.packageStoreClient.packages
        let onBar = try store.effectiveDocument["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        var reviews: [WidgetPackageInspection] = []
        for (entry, inspection) in chosenEntries where installed[entry.id] == nil || reused.contains(entry.id) {
            let record = try packages.record(id: entry.id)
            let directory = try packages.directory(id: entry.id, version: entry.version)
            if reused.contains(entry.id) || onBar.contains(where: { $0.id == entry.id && $0.version == entry.version && $0.enabled })
                && FileManager.default.fileExists(atPath: directory.path)
                && record?.source == PackageSource.storeID && record?.isLocal(version: entry.version) == false {
                // The bar's settings for it can change between Try on Bar and Use this bar.
                reused.insert(entry.id)
                let saved = try WidgetSetup(store: store).savedSettings(for: inspection.manifest)
                installed[entry.id] = (inspection, saved.merging(settings(for: inspection.manifest)) { $1 })
            } else if inspection.requiresReview {
                reviews.append(inspection)
            } else {
                let inspection = try await store.packageStoreClient.installWithoutReview(entry)
                installed[entry.id] = (inspection, settings(for: inspection.manifest))
            }
        }
        guard reviews.isEmpty else {
            self.reviews = reviews
            pending = action
            return false
        }
        return true
    }

    /// With the look ticked and every screen, removes the bar's own look. With a widget ticked, removes the bar's
    /// widgets, packages and their places, then adds the link's ticked widgets. Widgets that included files add stay.
    /// With a notched display under a top bar, the laptop screen's layout puts the centered widgets left of the notch: the
    /// bar puts them right of it with the right ones, where a bar made on a wider screen doesn't fit.
    private func edits(in store: BarStore, on kind: ScreenKind?) throws -> [ConfigurationEdit] {
        let main = try store.configurationStore.editedMainDocument()
        var removal: [String: ConfigurationValue] = [:]
        if appliesLook, kind == nil {
            var loader = ConfigurationLoader()
            let theme = try loader.readPackage(at: look.choice.directory, manifest: look.choice.manifest, settings: [:]).values
            removal = try savingLook(of: main, into: theme).removal
        }
        guard replacesWidgets else { return [ConfigurationEdit(action: .unset, properties: removal)] }
        removal.merge([
            "widgets": .null, "widgetOverrides": .null, "widgetOrder": .null, "packages": .null,
            "screens": .object(Dictionary(uniqueKeysWithValues: ScreenKind.allCases.map { ($0.rawValue, .object(["layout": .null])) }))
        ]) { $1 }
        let profiles = try main["profiles"]?.decoded([ConfigurationProfile].self) ?? []
        if !profiles.isEmpty {
            let widgets = ConfigurationValue.object(["widgets": .null, "widgetOverrides": .null, "widgetOrder": .null])
            removal["profiles"] = .object(Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, .object(["configuration": widgets])) }))
        }
        var edits = try (main["widgets"]?.decoded([[String: ConfigurationValue]].self) ?? []).compactMap { try $0["id"]?.decoded(String.self) }
            .map { ConfigurationEdit(action: .remove, id: $0) }
        edits.append(ConfigurationEdit(action: .unset, properties: removal))
        var ids = Set(builtIns.map(\.id)).subtracting(unticked)
        for (entry, _) in chosenEntries {
            let (inspection, settings) = installed[entry.id]!
            edits.append(ConfigurationEdit(action: .package, properties: [
                "id": .string(entry.id), "version": .string(inspection.manifest.version), "settings": .object(settings)
            ]))
            ids.formUnion(inspection.widgets.map(\.id))
        }
        // The link's groups come with its look, so without it a widget keeps only a group this bar has. The main file names
        // each group a widget keeps, so the widget stays valid once another theme is chosen.
        var named: [String: ConfigurationValue] = [:]
        func grouped(_ properties: [String: ConfigurationValue]) -> [String: ConfigurationValue] {
            guard case let .string(group)? = properties["group"] else { return properties }
            guard appliesLook || store.configuration?.groups[group] != nil else { return properties.filter { $0.key != "group" } }
            named[group] = .object([:])
            return properties
        }
        for (widget, builtIn) in zip(link.widgets, builtIns) where !unticked.contains(builtIn.id) {
            edits.append(ConfigurationEdit(action: .add, properties: grouped(widget)))
        }
        // An unticked widget of a package another widget needs comes with the package, hidden.
        for (id, properties) in link.widgetOverrides.sorted(by: { $0.key < $1.key }) where ids.contains(id) {
            edits.append(ConfigurationEdit(action: .set, id: id, properties: unticked.contains(id) ? ["enabled": .bool(false)] : grouped(properties)))
        }
        if !named.isEmpty { edits.append(ConfigurationEdit(action: .groups, properties: named)) }
        edits.append(ConfigurationEdit(action: .reorder, ids: link.widgetOrder.filter { ids.contains($0) && !unticked.contains($0) }))
        let widgets = previewWidgets
        if hasNotchedDisplay(), store.configuration?.onScreen(.laptop).bar.position == .top,
           widgets.contains(where: { $0.position == .center }) {
            func ids(_ positions: [WidgetPosition]) -> ConfigurationValue {
                .array(positions.flatMap { position in widgets.filter { $0.position == position } }.map { .string($0.id) })
            }
            edits.append(ConfigurationEdit(action: .screens, properties: [ScreenKind.laptop.rawValue: .object(["layout": .object([
                "left": ids([.left]), "notchLeft": ids([.notchLeft, .center]), "notchRight": ids([.notchRight]), "right": ids([.right])
            ])])]))
        }
        return edits
    }

    /// What a Store package does, in one line of plain words: the commands it runs, the hosts it reaches and the
    /// permissions it needs.
    private static func summary(of inspection: WidgetPackageInspection) -> String {
        let manifest = inspection.manifest
        var parts: [String] = []
        if inspection.commands.count == 1 { parts.append("Runs a script") }
        if inspection.commands.count > 1 { parts.append("Runs \(inspection.commands.count) commands") }
        if !manifest.hosts.isEmpty { parts.append("Connects to \(manifest.hosts.formatted(.list(type: .and)))") }
        if !manifest.permissions.isEmpty {
            parts.append("Needs \(manifest.permissions.map(\.rawValue.capitalized).formatted(.list(type: .and))) access")
        }
        return parts.isEmpty ? "Runs nothing, stays offline" : parts.joined(separator: " · ")
    }
}
