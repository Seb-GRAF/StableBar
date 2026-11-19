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
        func drawn(_ appearance: String) throws -> Configuration {
            let context = ConfigurationContext(appearance: appearance, theme: choice.manifest.id)
            return try ConfigurationValue.object(loader.finish(layer, context: context)).decoded(Configuration.self)
        }
        light = try drawn("light")
        dark = try drawn("dark")
    }

    func configuration(for appearance: BarAppearance) -> Configuration {
        appearance == .dark ? dark : light
    }
}
