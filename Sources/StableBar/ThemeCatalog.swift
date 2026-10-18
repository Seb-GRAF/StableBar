import Foundation

let themeTokens: [(name: String, title: String)] = [
    ("surface", "Surface"), ("surfaceRaised", "Raised surface"), ("text", "Text"), ("textMuted", "Muted text"),
    ("accent", "Accent"), ("track", "Track"), ("hairline", "Hairline"), ("warning", "Warning"), ("critical", "Critical")
]

struct ThemeChoice: Sendable {
    let manifest: WidgetPackageManifest
    let directory: URL
    let isBundled: Bool

    var key: String { isBundled ? manifest.id : manifest.versionKey }
    var title: String { isBundled ? manifest.name : "\(manifest.name) · \(manifest.version)" }
    var selection: [String: ConfigurationValue] {
        isBundled ? ["id": .string(manifest.id)] : ["id": .string(manifest.id), "version": .string(manifest.version)]
    }
}

func themeChoices(packages: URL, themesDirectory: URL? = bundledThemesDirectory) -> [ThemeChoice] {
    let bundled = ((themesDirectory.flatMap {
        try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    }) ?? []).filter { $0.lastPathComponent != "built-in" }.compactMap { directory in
        (try? WidgetPackageStore(directory: directory).manifest(at: directory)).map { ThemeChoice(manifest: $0, directory: directory, isBundled: true) }
    }
    let installed = ((try? WidgetPackageStore(directory: packages).list()) ?? []).filter { $0.kind == .theme }.map {
        ThemeChoice(manifest: $0, directory: packages.appending(path: $0.id).appending(path: $0.version), isBundled: false)
    }
    return bundled.sorted { $0.manifest.name < $1.manifest.name } + installed
}

struct ThemeCatalog {
    let packages: URL
    var themesDirectory: URL? = bundledThemesDirectory

    var choices: [ThemeChoice] {
        let builtIn = themesDirectory.flatMap { directory in
            let source = directory.appending(path: "built-in")
            return (try? WidgetPackageStore(directory: directory).manifest(at: source)).map {
                ThemeChoice(manifest: $0, directory: source, isBundled: true)
            }
        }
        return [builtIn].compactMap { $0 } + themeChoices(packages: packages, themesDirectory: themesDirectory)
    }
}

extension ThemeChoice {
    var isBuiltIn: Bool { isBundled && manifest.id == "built-in" }
    var edit: ConfigurationEdit { ConfigurationEdit(action: .theme, properties: isBuiltIn ? nil : selection) }
}
