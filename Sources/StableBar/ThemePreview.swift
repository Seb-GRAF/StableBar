import AppKit

/// Composes the same user layers as the real bar, replacing only the theme. It never applies a
/// configuration to a running store, so composing a preview cannot start scripts or providers.
struct ThemePreview {
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
        var loader = ConfigurationLoader()
        loader.themesDirectory = themesDirectory
        let layer = try loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: settings)
        return try loader.load(configurationURL, data: configurationData(document), context: context, previewTheme: layer)
    }

    @MainActor static func snapshot(_ configuration: Configuration, from source: BarStore) -> BarStore {
        let preview = BarStore(configurationURL: source.configurationURL, themesDirectory: source.themesDirectory)
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
