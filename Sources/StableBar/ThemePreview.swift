import AppKit

/// Composes the same user layers as the real bar, replacing only the theme. It never applies a
/// configuration to a running store, so composing a preview cannot start scripts or providers.
struct ThemePreview: Sendable {
    struct Request: Sendable {
        let model: ThemePreview
        let choice: ThemeChoice
        let document: [String: ConfigurationValue]
        let context: ConfigurationContext
        let settings: [String: ConfigurationValue]

        func compose() throws -> Composition {
            try model.compose(for: choice, document: document, context: context, settings: settings)
        }
    }

    struct Composition: Sendable {
        let configuration: Configuration
        let profiles: [ConfigurationProfile]
        let pinnedProfile: String?
        let profileAppearance: String?

        func changesAppearance(from previous: ConfigurationContext, to next: ConfigurationContext) -> Bool {
            if configuration.bar.appearance == nil && previous.appearance != next.appearance { return true }
            guard pinnedProfile == nil else { return false }
            var previous = previous
            var next = next
            if let profileAppearance {
                previous.appearance = profileAppearance
                next.appearance = profileAppearance
            }
            return profiles.contains { ($0.when?.matches(previous) ?? true) != ($0.when?.matches(next) ?? true) }
        }
    }

    @MainActor struct Snapshot {
        let store: BarStore
        let date = Date.now
    }

    let configurationURL: URL
    var themesDirectory: URL? = bundledThemesDirectory

    func layer(for choice: ThemeChoice, settings: [String: ConfigurationValue] = [:],
               context: ConfigurationContext) throws -> ConfigurationLayer {
        var loader = ConfigurationLoader()
        loader.themesDirectory = themesDirectory
        var layer = try loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: settings)
        for profile in try layer.values["profiles"]?.decoded([ConfigurationProfile].self) ?? [] {
            if profile.when?.matches(context) ?? true {
                try layer.merge(ConfigurationLayer(values: profile.configuration, origins: [:]))
            }
        }
        layer.values["profiles"] = nil
        return layer
    }

    func configuration(for choice: ThemeChoice, document: [String: ConfigurationValue],
                       context: ConfigurationContext, settings: [String: ConfigurationValue] = [:]) throws -> Configuration {
        try compose(for: choice, document: document, context: context, settings: settings).configuration
    }

    func compose(for choice: ThemeChoice, document: [String: ConfigurationValue],
                 context: ConfigurationContext, settings: [String: ConfigurationValue] = [:]) throws -> Composition {
        var loader = ConfigurationLoader()
        loader.themesDirectory = themesDirectory
        let layer = try loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: settings)
        let configuration = try loader.load(configurationURL, data: configurationData(document), context: context, previewTheme: layer)
        return Composition(configuration: configuration, profiles: loader.profiles, pinnedProfile: loader.pinnedProfile,
                           profileAppearance: loader.profileAppearance)
    }

    @MainActor static func snapshot(_ configuration: Configuration, from source: BarStore) -> BarStore {
        let preview = BarStore(configurationURL: source.configurationURL, themesDirectory: source.themesDirectory, isPreview: true)
        preview.configuration = configuration
        preview.context = source.context
        preview.activeApp = source.activeApp
        preview.activeDisplayID = source.activeDisplayID
        preview.workspaceStore.source = source.workspaceStore.source
        preview.workspaceStore.workspaces = source.workspaceStore.workspaces
        preview.workspaceStore.error = source.workspaceStore.error
        preview.workspaceStore.acceptMode(source.workspaceStore.mode)
        preview.scripts = source.scripts.mapValues { script in
            let copy = ScriptWidget()
            copy.output = script.output
            copy.samples = script.samples
            copy.error = script.error
            return copy
        }
        preview.preparePresentations()
        for (id, presentation) in preview.presentations {
            presentation.setStaticTemporaryFields(source.presentations[id]?.temporaryFields)
        }
        return preview
    }

    @MainActor static func display(for store: BarStore) -> BarDisplay {
        let screens = NSScreen.screens
        if screens.indices.contains(store.activeDisplayID - 1) { return BarDisplay(screen: screens[store.activeDisplayID - 1]) }
        return BarDisplay(id: store.activeDisplayID, isBuiltIn: true, isMain: true, notch: nil)
    }

    @MainActor static func units(in store: BarStore, display: BarDisplay) -> [BarUnit] {
        guard let configuration = store.configuration else { return [] }
        let activeID = store.workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? store.activeDisplayID
        let positions = WidgetPosition.allCases
        let widgets = configuration.widgets.filter { widget in
            let presentation = store.presentations[widget.id]
            if widget.content == .workspaces && widget.layout == nil && store.workspaceStore.error == nil
                && store.workspaceStore.workspaces(on: display.id, showEmpty: widget.workspace?.showEmpty == true).isEmpty {
                return false
            }
            return widget.enabled && widget.content != .spacer && presentation?.hidden != true
                && (presentation?.display ?? widget.display).includes(display, activeID: activeID)
        }.sorted { positions.firstIndex(of: $0.position)! < positions.firstIndex(of: $1.position)! }
        return BarUnit.make(widgets: widgets, groups: configuration.groups)
    }

    static func usesDarkAppearance(_ configuration: Configuration, context: ConfigurationContext) -> Bool {
        configuration.bar.appearance.map { $0 == .dark } ?? (context.appearance == "dark")
    }
}
