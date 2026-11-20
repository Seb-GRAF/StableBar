import Foundation

let themeTokens: [(name: String, title: String)] = [
    ("surface", "Surface"), ("surfaceRaised", "Raised surface"), ("text", "Text"), ("textMuted", "Muted text"),
    ("accent", "Accent"), ("track", "Track"), ("hairline", "Hairline"), ("warning", "Warning"), ("critical", "Critical")
]

/// The included themes, in the order the gallery, setup and Try Themes show them.
let includedThemeIDs = ["clear", "glass", "tonal", "slim", "dot", "gloss"]

/// Themes retired before retired themes moved to the Store: an update installs a copy of the one a configuration selects.
let legacyThemeIDs: Set<String> = [
    "graphite", "island", "menu-bar", "minimal", "paper", "slate", "terminal",
    "blueprint", "broadsheet", "brutalist", "everforest", "handheld", "kanagawa", "platinum", "rose-pine", "synthwave"
]

/// Whether a theme link or Save as Theme can't take `id`: a theme StableBar includes or included has it, or Classic,
/// which an update installs from the app.
func isReservedThemeID(_ id: String, themesDirectory: URL?) -> Bool {
    id == "classic" || legacyThemeIDs.contains(id)
        || themesDirectory.map { FileManager.default.fileExists(atPath: $0.appending(path: id).path) } == true
}

struct ThemeChoice: Sendable {
    let manifest: WidgetPackageManifest
    let directory: URL
    let isBundled: Bool

    var key: String { isBundled ? manifest.id : manifest.versionKey }
    /// A bundled theme that still loads for a configuration that selects it, but no longer shows in the gallery.
    var isLegacy: Bool { isBundled && !includedThemeIDs.contains(manifest.id) }
    var title: String { isLegacy ? "Custom" : (isBundled ? manifest.name : "\(manifest.name) · \(manifest.version)") }
    var selection: [String: ConfigurationValue] {
        isBundled ? ["id": .string(manifest.id)] : ["id": .string(manifest.id), "version": .string(manifest.version)]
    }
}

func themeChoices(packages: URL, themesDirectory: URL? = bundledThemesDirectory, selectedKey: String? = nil) -> [ThemeChoice] {
    let bundled = ((themesDirectory.flatMap {
        try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    }) ?? []).compactMap { directory in
        (try? WidgetPackageStore(directory: directory).manifest(at: directory)).map { ThemeChoice(manifest: $0, directory: directory, isBundled: true) }
    }
    let installed = ((try? WidgetPackageStore(directory: packages).list()) ?? []).filter { $0.kind == .theme }.map {
        ThemeChoice(manifest: $0, directory: packages.appending(path: $0.id).appending(path: $0.version), isBundled: false)
    }
    let order = { (choice: ThemeChoice) in includedThemeIDs.firstIndex(of: choice.manifest.id) ?? includedThemeIDs.count }
    return (bundled.sorted { order($0) < order($1) } + installed).filter { !$0.isLegacy || $0.key == selectedKey }
}

struct ThemeCatalog {
    let packages: URL
    var themesDirectory: URL? = bundledThemesDirectory
    var selectedKey: String? = nil

    var choices: [ThemeChoice] {
        themeChoices(packages: packages, themesDirectory: themesDirectory, selectedKey: selectedKey)
    }
}

/// A theme a profile can match, by ID whatever its version.
struct ProfileThemeOption: Equatable {
    let id: String
    let name: String
}

extension ThemeCatalog {
    /// Each theme once.
    var profileThemeOptions: [ProfileThemeOption] {
        var options: [ProfileThemeOption] = []
        for choice in choices where !choice.isLegacy && !options.contains(where: { $0.id == choice.manifest.id }) {
            options.append(ProfileThemeOption(id: choice.manifest.id, name: choice.manifest.name))
        }
        return options
    }
}

extension [ThemeChoice] {
    /// Updates keep earlier versions installed, so each installed theme shows once: its versions in `selected`, or else
    /// its newest.
    func onePerTheme(keeping selected: Set<String>) -> [ThemeChoice] {
        filter { choice in
            choice.isBundled || selected.contains(choice.key) || !contains { other in
                guard !other.isBundled, other.manifest.id == choice.manifest.id else { return false }
                let order = compareReleases(other.manifest.version, choice.manifest.version)
                // Equal releases, such as 1.0 and 1.0.0, keep the later spelling.
                return selected.contains(other.key) || order == .orderedDescending || order == .orderedSame && other.manifest.version > choice.manifest.version
            }
        }
    }
}

extension ThemeChoice {
    var isBuiltIn: Bool { isBundled && manifest.id == "built-in" }
    var edit: ConfigurationEdit { ConfigurationEdit(action: .theme, properties: isBuiltIn ? nil : selection) }
}
