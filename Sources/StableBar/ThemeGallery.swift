import Foundation
import Observation

@MainActor @Observable
final class ThemeGallery {
    private unowned let store: BarStore
    private let client: PackageStoreClient
    private var downloaded: [String: ThemeChoice] = [:]
    private var entries: [PackageIndex.Entry] = []
    private(set) var choices: [ThemeChoice] = []
    private(set) var previews: [String: Configuration] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var progress: [String: String] = [:]
    private(set) var storeUnavailable = false
    private(set) var overrides = ThemeOverrides(main: [:], theme: [:], widgets: [])

    init(store: BarStore, client: PackageStoreClient? = nil) {
        self.store = store
        self.client = client ?? store.packageStoreClient
    }

    var selectedKey: String {
        let selection = try? store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
        guard let selection, selection.enabled else { return "built-in" }
        return selection.key
    }

    var storeThemes: [PackageIndex.Entry] {
        entries.filter { entry in
            entry.kind == .theme && !choices.contains { !$0.isBundled && $0.manifest.versionKey == entry.versionKey }
        }
    }

    func refresh() {
        let catalog = ThemeCatalog(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                   themesDirectory: store.themesDirectory)
        choices = catalog.choices
        let preview = ThemePreview(configurationURL: store.configurationURL, themesDirectory: store.themesDirectory)
        overrides = ThemeOverrides(main: [:], theme: [:], widgets: [])
        do {
            let document = try store.editedDocument([])
            var looks: [String: Configuration] = [:]
            let uninstalled = downloaded.values.filter { downloaded in !choices.contains { $0.key == downloaded.key } }
            for choice in choices + uninstalled {
                do {
                    looks[choice.key] = try preview.configuration(for: choice, document: document, context: store.context,
                                                                  settings: settings(for: choice))
                } catch { errors[choice.key] = errorMessage(error) }
            }
            previews = looks
            if let selected = choices.first(where: { $0.key == selectedKey }) {
                var context = store.context
                if let appearance = store.configuration?.bar.appearance { context.appearance = appearance.rawValue }
                let theme = try preview.layer(for: selected, settings: settings(for: selected), context: context)
                let main = try store.editedDocument([], replaying: store.customizationEdits)
                overrides = ThemeOverrides(main: main, theme: theme.values, widgets: store.configuration?.widgets ?? [],
                                           activeProfiles: store.activeProfiles)
            }
        } catch {
            errors[selectedKey] = errorMessage(error)
        }
    }

    func select(_ choice: ThemeChoice) {
        perform(on: choice.key) {
            var edit = choice.edit
            if choice.isBuiltIn {
                let root = try store.editedDocument([edit], replaying: [])
                var loader = ConfigurationLoader()
                loader.themesDirectory = store.themesDirectory
                let document = try loader.compose(store.configurationURL, data: configurationData(root), context: store.context)
                if let inherited = try document["theme"]?.decoded(WidgetPackageSelection.self), inherited.enabled {
                    edit.properties = choice.selection
                }
            }
            try store.customizationHistory.change(edit)
        }
        refresh()
    }

    func loadStore() async {
        do {
            entries = try await client.index().packages
            storeUnavailable = false
        } catch {
            storeUnavailable = true
            return
        }
        for entry in storeThemes {
            guard !Task.isCancelled else { return }
            do {
                let inspection = try await client.package(entry)
                downloaded[entry.versionKey] = ThemeChoice(manifest: inspection.manifest, directory: inspection.directory, isBundled: false)
                errors[entry.versionKey] = nil
                refresh()
            } catch { errors[entry.versionKey] = errorMessage(error) }
        }
    }

    func get(_ entry: PackageIndex.Entry) async {
        let key = entry.versionKey
        guard progress[key] == nil else { return }
        progress[key] = "Downloading…"
        errors[key] = nil
        defer { progress[key] = nil; refresh() }
        do {
            _ = try await client.package(entry)
            progress[key] = "Installing…"
            let installed = try await client.installWithoutReview(entry)
            progress[key] = "Applying…"
            perform(on: key) {
                try store.customizationHistory.change(ThemeChoice(manifest: installed.manifest, directory: installed.directory, isBundled: false).edit)
            }
        } catch { errors[key] = errorMessage(error) }
    }

    private func settings(for choice: ThemeChoice) -> [String: ConfigurationValue] {
        let selection = try? store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
        guard let selection, selection.key == choice.key else { return [:] }
        return selection.settings
    }

    private func perform(on key: String, _ action: () throws -> Void) {
        do { try action(); errors[key] = nil }
        catch {
            let message = errorMessage(error)
            errors[key] = message
            // This error is presented on its card, including a failed history write.
            if store.customizationHistory.error == message { store.customizationHistory.error = nil }
        }
    }
}

extension PackageIndex.Entry {
    var versionKey: String { "\(id)/\(version)" }
}
