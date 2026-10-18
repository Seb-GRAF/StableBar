import Foundation
import Observation

@MainActor @Observable
final class ThemeGallery {
    private let store: BarStore
    private let client: PackageStoreClient
    private let refreshDelay: Duration
    private let compose: @Sendable (ThemePreview.Request) throws -> ThemePreview.Composition
    private var compositions: [String: ThemePreview.Composition] = [:]
    private var generation = 0
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    private var downloaded: [String: ThemeChoice] = [:]
    private var entries: [PackageIndex.Entry] = []
    private(set) var choices: [ThemeChoice] = []
    private(set) var previews: [String: ThemePreview.Snapshot] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var progress: [String: String] = [:]
    private(set) var storeUnavailable = false
    private(set) var overrides = ThemeOverrides(main: [:], theme: [:], widgets: [])

    init(store: BarStore, client: PackageStoreClient? = nil, refreshDelay: Duration = .milliseconds(250),
         compose: @escaping @Sendable (ThemePreview.Request) throws -> ThemePreview.Composition = { try $0.compose() }) {
        self.store = store
        self.client = client ?? store.packageStoreClient
        self.refreshDelay = refreshDelay
        self.compose = compose
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

    func configurationChanged() {
        updateOverrides()
        scheduleRefresh()
    }

    func contextChanged(from previous: ConfigurationContext) {
        guard (compositions.isEmpty && previous != store.context)
            || compositions.values.contains(where: { $0.changesAppearance(from: previous, to: store.context) }) else { return }
        updateOverrides()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        generation += 1
        let generation = generation
        refreshTask = Task { [weak self, refreshDelay] in
            do { try await Task.sleep(for: refreshDelay) }
            catch { return }
            await self?.buildPreviews(generation: generation)
        }
    }

    func refresh() async {
        refreshTask?.cancel()
        generation += 1
        await buildPreviews(generation: generation)
    }

    private func buildPreviews(generation: Int) async {
        do {
            let document = try store.editedMainDocument()
            let context = store.context
            let model = ThemePreview(configurationURL: store.configurationURL, themesDirectory: store.themesDirectory)
            let catalog = ThemeCatalog(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                       themesDirectory: store.themesDirectory)
            let downloaded = Array(downloaded.values)
            let selection = try? store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
            let compose = compose
            let (choices, results) = await Task.detached {
                let choices = catalog.choices
                let uninstalled = downloaded.filter { choice in !choices.contains { $0.key == choice.key } }
                let results = (choices + uninstalled).map { choice in
                    let request = ThemePreview.Request(model: model, choice: choice, document: document, context: context,
                                                       settings: selection.flatMap { $0.key == choice.key ? $0.settings : nil } ?? [:])
                    return (choice.key, Result { try compose(request) })
                }
                return (choices, results)
            }.value
            guard self.generation == generation, !Task.isCancelled else { return }
            if results.contains(where: { (try? $0.1.get().changesAppearance(from: context, to: store.context)) == true }) {
                scheduleRefresh()
                return
            }
            self.choices = choices
            let available = Set(choices.map(\.key) + self.downloaded.values.map(\.key))
            previews = previews.filter { available.contains($0.key) }
            compositions = compositions.filter { available.contains($0.key) }
            for (key, result) in results { accept(result, key: key, context: context) }
            updateOverrides()
        } catch { errors[selectedKey] = errorMessage(error) }
    }

    private func buildPreview(_ choice: ThemeChoice) async {
        do {
            let generation = generation
            let context = store.context
            let request = ThemePreview.Request(
                model: ThemePreview(configurationURL: store.configurationURL, themesDirectory: store.themesDirectory),
                choice: choice, document: try store.editedMainDocument(), context: context, settings: settings(for: choice))
            let compose = compose
            let result = await Task.detached { Result { try compose(request) } }.value
            guard self.generation == generation, !Task.isCancelled else { return }
            if (try? result.get().changesAppearance(from: context, to: store.context)) == true {
                scheduleRefresh()
                return
            }
            accept(result, key: choice.key, context: context)
        } catch { errors[choice.key] = errorMessage(error) }
    }

    private func accept(_ result: Result<ThemePreview.Composition, Error>, key: String, context: ConfigurationContext) {
        switch result {
        case let .success(composition):
            compositions[key] = composition
            let snapshot = ThemePreview.snapshot(composition.configuration, from: store)
            snapshot.context = context
            previews[key] = ThemePreview.Snapshot(store: snapshot)
        case let .failure(error):
            previews[key] = nil
            compositions[key] = nil
            errors[key] = errorMessage(error)
        }
    }

    private func updateOverrides() {
        overrides = ThemeOverrides(main: [:], theme: [:], widgets: [])
        guard let selected = choices.first(where: { $0.key == selectedKey }) else { return }
        do {
            var context = store.context
            if let appearance = store.configuration?.bar.appearance { context.appearance = appearance.rawValue }
            let model = ThemePreview(configurationURL: store.configurationURL, themesDirectory: store.themesDirectory)
            let theme = try model.layer(for: selected, settings: settings(for: selected), context: context)
            let main = try store.editedMainDocument(replaying: store.customizationEdits)
            overrides = ThemeOverrides(main: main, theme: theme.values, widgets: store.configuration?.widgets ?? [],
                                       activeProfiles: store.activeProfiles)
        } catch { errors[selectedKey] = errorMessage(error) }
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
        configurationChanged()
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
                let choice = ThemeChoice(manifest: inspection.manifest, directory: inspection.directory, isBundled: false)
                downloaded[entry.versionKey] = choice
                errors[entry.versionKey] = nil
                if previews[entry.versionKey] == nil { await buildPreview(choice) }
            } catch { errors[entry.versionKey] = errorMessage(error) }
        }
    }

    func get(_ entry: PackageIndex.Entry) async {
        let key = entry.versionKey
        guard progress[key] == nil else { return }
        progress[key] = "Downloading…"
        errors[key] = nil
        defer { progress[key] = nil; configurationChanged() }
        do {
            _ = try await client.package(entry)
            progress[key] = "Installing…"
            let installed = try await client.installWithoutReview(entry)
            let choice = ThemeChoice(manifest: installed.manifest, directory: installed.directory, isBundled: false)
            if !choices.contains(where: { $0.key == choice.key }) { choices.append(choice) }
            progress[key] = "Applying…"
            perform(on: key) { try store.customizationHistory.change(choice.edit) }
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
