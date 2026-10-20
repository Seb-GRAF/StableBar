import Foundation
import Observation

@MainActor @Observable
final class ThemeGallery {
    private let store: BarStore
    private let client: PackageStoreClient
    private let refreshDelay: Duration
    private let loadPreview: @Sendable (ThemeChoice, URL?) throws -> ThemePreview
    private var generation = 0
    private var overrideError: String?
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    private var downloaded: [String: ThemeChoice] = [:]
    private var entries: [PackageIndex.Entry] = []
    private(set) var choices: [ThemeChoice] = []
    private(set) var previews: [String: ThemePreview] = [:]
    private(set) var previewErrors: [String: String] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var progress: [String: String] = [:]
    private(set) var storeUnavailable = false
    private(set) var overrides = ThemeOverrides(main: [:], theme: [:], widgets: [])

    init(store: BarStore, client: PackageStoreClient? = nil, refreshDelay: Duration = .milliseconds(250),
         loadPreview: @escaping @Sendable (ThemeChoice, URL?) throws -> ThemePreview = { try ThemePreview(choice: $0, themesDirectory: $1) }) {
        self.store = store
        self.client = client ?? store.packageStoreClient
        self.refreshDelay = refreshDelay
        self.loadPreview = loadPreview
    }

    var selectedKey: String { store.selectedThemeKey }

    var storeThemes: [PackageIndex.Entry] {
        entries.filter { entry in
            entry.kind == .theme && !choices.contains { !$0.isBundled && $0.manifest.versionKey == entry.versionKey }
        }
    }

    func error(for key: String) -> String? {
        errors[key] ?? previewErrors[key] ?? (key == selectedKey ? overrideError : nil)
    }

    func configurationChanged() {
        updateOverrides()
        scheduleRefresh()
    }

    var previewAppearance: BarAppearance {
        store.configuration?.bar.appearance ?? (store.context.appearance == "dark" ? .dark : .light)
    }

    func contextChanged() { updateOverrides() }

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
        let catalog = ThemeCatalog(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                   themesDirectory: store.themesDirectory, selectedKey: store.selectedThemeKey)
        let choices = await Task.detached { catalog.choices }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        self.choices = choices
        let uninstalled = downloaded.values.filter { choice in !choices.contains { $0.key == choice.key } }
        let missing = (choices + uninstalled).filter { previews[$0.key] == nil }
        let loadPreview = loadPreview
        let themesDirectory = store.themesDirectory
        let results = await Task.detached {
            missing.map { choice in
                (choice.key, Result { try loadPreview(choice, themesDirectory) })
            }
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        let available = Set(choices.map(\.key) + downloaded.values.map(\.key))
        previews = previews.filter { available.contains($0.key) }
        previewErrors = previewErrors.filter { available.contains($0.key) }
        for (key, result) in results { accept(result, key: key) }
        updateOverrides()
    }

    private func buildPreview(_ choice: ThemeChoice) async {
        let generation = generation
        let loadPreview = loadPreview
        let themesDirectory = store.themesDirectory
        let result = await Task.detached { Result { try loadPreview(choice, themesDirectory) } }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        accept(result, key: choice.key)
    }

    private func accept(_ result: Result<ThemePreview, Error>, key: String) {
        switch result {
        case let .success(preview):
            previewErrors[key] = nil
            previews[key] = preview
        case let .failure(error):
            previews[key] = nil
            previewErrors[key] = errorMessage(error)
        }
    }

    private func updateOverrides() {
        overrideError = nil
        overrides = ThemeOverrides(main: [:], theme: [:], widgets: [])
        guard let selected = choices.first(where: { $0.key == selectedKey }) else { return }
        do {
            let theme = try selected.overrideLayer(settings: store.themeSettings(for: selected, in: store.effectiveDocument),
                                                   activeProfiles: store.activeProfiles)
            let main = try store.editedMainDocument(replaying: store.customizationEdits)
            overrides = ThemeOverrides(main: main, theme: theme.values, widgets: store.configuration?.widgets ?? [],
                                       activeProfiles: store.activeProfiles)
        } catch { overrideError = errorMessage(error) }
    }

    func select(_ choice: ThemeChoice) {
        perform(on: choice.key) {
            try store.customizationHistory.change(store.themeEdit(for: choice))
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
            perform(on: key) { try store.customizationHistory.change(store.themeEdit(for: choice)) }
        } catch { errors[key] = errorMessage(error) }
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
