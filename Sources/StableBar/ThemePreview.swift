import Foundation

/// A theme's own look over Built-in, with no user configuration or running bar state.
struct ThemePreview: Sendable {
    let light: Configuration
    let dark: Configuration

    init(choice: ThemeChoice, themesDirectory: URL?) throws {
        var loader = ConfigurationLoader()
        var layer = ConfigurationLayer(values: ["widgets": .array([])], origins: [:])
        if let themesDirectory {
            let directory = themesDirectory.appending(path: "built-in")
            let manifest = try WidgetPackageStore(directory: themesDirectory).manifest(at: directory)
            try layer.merge(loader.readPackage(at: directory, manifest: manifest, settings: [:]))
        }
        if !choice.isBuiltIn || themesDirectory == nil {
            try layer.merge(loader.readPackage(at: choice.directory, manifest: choice.manifest, settings: [:]))
        }
        light = try ConfigurationValue.object(loader.finish(layer, context: ConfigurationContext(appearance: "light"))).decoded(Configuration.self)
        dark = try ConfigurationValue.object(loader.finish(layer, context: ConfigurationContext(appearance: "dark"))).decoded(Configuration.self)
    }

    func configuration(for appearance: BarAppearance) -> Configuration {
        appearance == .dark ? dark : light
    }
}
