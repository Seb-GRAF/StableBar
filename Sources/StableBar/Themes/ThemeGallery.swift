import Foundation
import Observation

let savedThemeBarProperties: Set<String> = [
    "height", "margin", "inset", "spacing", "background", "style", "divider", "notchWidth", "notchSpacing", "fillNotch",
    "popupOffset", "glass"
]

/// `theme` with the look of `main` merged in, as Save as Theme saves it, and the unset that takes that look out of `main`.
func savingLook(of main: [String: ConfigurationValue], into theme: [String: ConfigurationValue]) throws
    -> (theme: [String: ConfigurationValue], removal: [String: ConfigurationValue]) {
    var moved: [String: ConfigurationValue] = [:]
    var removal: [String: ConfigurationValue] = [:]
    for property in themeLookKeys where main[property] != nil {
        moved[property] = main[property]
        removal[property] = .null
    }
    let bar = try (main["bar"]?.decoded([String: ConfigurationValue].self) ?? [:]).filter {
        savedThemeBarProperties.contains($0.key)
    }
    if !bar.isEmpty {
        moved["bar"] = .object(bar)
        removal["bar"] = .object(bar.mapValues { _ in .null })
    }
    let tokens = try main["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:]
    let themed = try theme["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:]
    if !tokens.isEmpty { moved["tokens"] = .object(tokens) }
    let themeColors = tokens.filter { name, _ in themed[name] != nil || themeTokens.contains { $0.name == name } }
    if !themeColors.isEmpty { removal["tokens"] = .object(themeColors.mapValues { _ in .null }) }
    return (theme.merging(moved) { $1.overriding($0) }, removal)
}

@MainActor @Observable
final class ThemeGallery {
    private let store: BarStore
    private let client: PackageStoreClient
    private let refreshDelay: Duration
    private let loadPreview: @Sendable (ThemeChoice, URL?) throws -> ThemePreview
    private var generation = 0
    private var editsError: String?
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    /// Store entry `key` → its downloaded theme. Store cards' previews, progress and errors use the same keys.
    private var downloaded: [String: ThemeChoice] = [:]
    private var entries: [PackageIndex.Entry] = []
    private(set) var sources: [PackageSource] = [.store]
    /// Package ID → the source that installed it, read on refresh.
    private(set) var records: [String: PackageInstallRecord] = [:]
    private(set) var choices: [ThemeChoice] = []
    private(set) var previews: [String: ThemePreview] = [:]
    private(set) var previewErrors: [String: String] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var progress: [String: String] = [:]
    private(set) var storeUnavailable = false
    /// The selected theme's edits, and the look values of the main file that apply under every theme.
    private(set) var edits = ThemeEdits.none
    /// The themes the main file keeps edits for.
    private(set) var editedThemes: Set<String> = []

    init(store: BarStore, client: PackageStoreClient? = nil, refreshDelay: Duration = .milliseconds(250),
         loadPreview: @escaping @Sendable (ThemeChoice, URL?) throws -> ThemePreview = { try ThemePreview(choice: $0, themesDirectory: $1) }) {
        self.store = store
        self.client = client ?? store.packageStoreClient
        self.refreshDelay = refreshDelay
        self.loadPreview = loadPreview
    }

    var selectedKey: String { store.configurationStore.selectedThemeKey }

    var linkedThemeIsActive: Bool {
        switch store.pendingLinks.theme?.state {
        case .ready, .trying: true
        default: false
        }
    }

    var selectedChoice: ThemeChoice? { choices.first { $0.key == selectedKey } }

    /// Store themes, without versions installed from their own source or from no source.
    /// Another source's copy of the same version keeps its card, whose Get explains the conflict.
    var storeThemes: [PackageIndex.Entry] {
        entries.filter { entry in
            guard entry.kind == .theme else { return false }
            guard choices.contains(where: { !$0.isBundled && $0.manifest.versionKey == entry.versionKey }) else { return true }
            guard let record = records[entry.id], !record.isLocal else { return false }
            return record.source != entry.sourceID
        }
    }

    func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? id
    }

    func source(of choice: ThemeChoice) -> PackageOrigin? {
        if choice.isBundled { return .included }
        return .installed(record: records[choice.manifest.id], version: choice.manifest.version,
                          listedInStore: entries.contains { $0.sourceID == PackageSource.storeID && $0.id == choice.manifest.id },
                          sources: sources)
    }

    func error(for key: String) -> String? {
        errors[key] ?? previewErrors[key] ?? (key == selectedKey ? editsError : nil)
    }

    func configurationChanged() {
        updateEdits()
        scheduleRefresh()
    }

    var previewAppearance: BarAppearance {
        store.configuration?.bar.appearance ?? (store.configurationStore.context.appearance == "dark" ? .dark : .light)
    }

    func contextChanged() { updateEdits() }

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

    /// Lists the themes without drawing their previews, so their names are known before Theme opens.
    func loadChoices() async {
        guard choices.isEmpty else { return }
        let catalog = ThemeCatalog(packages: store.configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                   themesDirectory: store.configurationStore.themesDirectory, selectedKey: store.configurationStore.selectedThemeKey)
        let loaded = await Task.detached { catalog.choices }.value
        if choices.isEmpty { choices = loaded }
    }

    func refresh() async {
        refreshTask?.cancel()
        generation += 1
        await buildPreviews(generation: generation)
    }

    private func buildPreviews(generation: Int) async {
        let catalog = ThemeCatalog(packages: store.configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                   themesDirectory: store.configurationStore.themesDirectory, selectedKey: store.configurationStore.selectedThemeKey)
        let choices = await Task.detached { catalog.choices }.value
        let records = (try? await client.records()) ?? records
        let sources = await client.sources
        guard self.generation == generation, !Task.isCancelled else { return }
        self.choices = choices
        self.records = records
        self.sources = sources
        let uninstalled = downloaded.filter { _, choice in !choices.contains { $0.key == choice.key } }
        let missing = (choices.map { ($0.key, $0) } + uninstalled.map { ($0.key, $0.value) }).filter { previews[$0.0] == nil }
        let loadPreview = loadPreview
        let themesDirectory = store.configurationStore.themesDirectory
        let results = await Task.detached {
            missing.map { key, choice in
                (key, Result { try loadPreview(choice, themesDirectory) })
            }
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        let linked = store.pendingLinks.theme.map { [$0.choice.linkedPreviewKey] } ?? []
        let available = Set(choices.map(\.key) + downloaded.keys + linked)
        previews = previews.filter { available.contains($0.key) }
        previewErrors = previewErrors.filter { available.contains($0.key) }
        for (key, result) in results { accept(result, key: key) }
        updateEdits()
        if let choice = store.pendingLinks.theme?.choice { await linkedPreview(for: choice) }
    }

    private func buildPreview(_ choice: ThemeChoice, key: String) async {
        let generation = generation
        let result = await previewResult(for: choice)
        guard self.generation == generation, !Task.isCancelled else { return }
        accept(result, key: key)
    }

    private func previewResult(for choice: ThemeChoice) async -> Result<ThemePreview, Error> {
        let loadPreview = loadPreview
        let themesDirectory = store.configurationStore.themesDirectory
        return await Task.detached { Result { try loadPreview(choice, themesDirectory) } }.value
    }

    func linkedPreview(for choice: ThemeChoice) async {
        guard previews[choice.linkedPreviewKey] == nil else { updateEdits(); return }
        let result = await previewResult(for: choice)
        guard !Task.isCancelled, store.pendingLinks.theme?.choice.directory == choice.directory else { return }
        accept(result, key: choice.linkedPreviewKey)
        updateEdits()
    }

    func dismissLinkedTheme(_ candidate: ThemeLinkCandidate) {
        candidate.discard()
        if store.pendingLinks.theme === candidate { store.pendingLinks.theme = nil }
        configurationChanged()
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

    private func updateEdits() {
        editsError = nil
        do {
            let main = try store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)
            editedThemes = ThemeEdits.editedThemes(in: main)
            let theme = try selectedChoice.map {
                try $0.overrideLayer(settings: store.configurationStore.themeSettings(for: $0, in: store.effectiveDocument),
                                     activeProfiles: store.activeProfiles).values
            } ?? [:]
            let widgets = store.configuration?.widgets ?? []
            edits = ThemeEdits(main: main, themeID: String(selectedKey.prefix { $0 != "/" }), theme: theme,
                               names: WidgetDisplayName.names(for: widgets, packageNames: store.widgetPackageNames,
                                                              providers: store.configuration?.providers ?? [:]))
        } catch {
            edits = .none
            editsError = errorMessage(error)
        }
    }

    func select(_ choice: ThemeChoice, on kind: ScreenKind? = nil, everyBar: Bool = false) {
        store.configurationStore.endThemeTrial()
        perform(on: choice.key) { try store.configurationStore.applyTheme(choice, on: kind, everyBar: everyBar) }
        configurationChanged()
    }

    /// Lists the themes of every source. Only the Store's failure is shown; private sources report theirs in the Store.
    func loadStore() async {
        let catalog = await client.catalog()
        entries = catalog.entries
        sources = await client.sources
        storeUnavailable = catalog.errors[PackageSource.storeID] != nil
        for entry in storeThemes {
            guard !Task.isCancelled else { return }
            do {
                let inspection = try await client.package(entry)
                let choice = ThemeChoice(manifest: inspection.manifest, directory: inspection.directory, isBundled: false)
                downloaded[entry.key] = choice
                errors[entry.key] = nil
                if previews[entry.key] == nil { await buildPreview(choice, key: entry.key) }
            } catch { errors[entry.key] = errorMessage(error) }
        }
    }

    /// Download and install errors stay on the Store card; applying the installed theme reports on its own card.
    func get(_ entry: PackageIndex.Entry, on kind: ScreenKind? = nil, everyBar: Bool = false) async {
        let key = entry.key
        guard progress[key] == nil else { return }
        progress[key] = "Downloading…"
        errors[key] = nil
        defer { progress[key] = nil; configurationChanged() }
        do {
            _ = try await client.package(entry)
            progress[key] = "Installing…"
            let installed = try await client.installWithoutReview(entry)
            records = (try? await client.records()) ?? records
            let choice = ThemeChoice(manifest: installed.manifest, directory: installed.directory, isBundled: false)
            if !choices.contains(where: { $0.key == choice.key }) { choices.append(choice) }
            if previews[choice.key] == nil, let preview = previews[key] { previews[choice.key] = preview }
            progress[key] = "Applying…"
            perform(on: choice.key) { try store.configurationStore.applyTheme(choice, on: kind, everyBar: everyBar) }
        } catch { errors[key] = errorMessage(error) }
    }

    /// Saves `current` with its edits as a new theme. Selecting it keeps the bar as it is; otherwise `current` stays
    /// selected without its edits.
    func save(_ current: ThemeChoice, as name: String, everyBar: Bool = false, selecting: Bool = true) async {
        let key = current.key
        errors[key] = nil
        defer { configurationChanged() }
        do {
            var loader = ConfigurationLoader()
            let theme = try loader.readPackage(at: current.directory, manifest: current.manifest,
                                               settings: store.configurationStore.themeSettings(for: current)).values
            let main = try store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)
            let edits = ThemeEdits(main: main, themeID: current.manifest.id)
            let saved = try savingLook(of: ThemeEdits.profile(for: current.manifest.id, in: main)?["configuration"]?
                .decoded([String: ConfigurationValue].self) ?? [:], into: theme)
            let id = packageSlug(name)
            let versions = try await client.installed().filter { $0.id == id }.map(\.version)
            var patch = 0
            while versions.contains("1.0.\(patch)") { patch += 1 }
            let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: source) }
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try configurationData(["id": .string(id), "name": .string(name), "version": .string("1.0.\(patch)"),
                                   "kind": .string("theme"), "entry": .string("config.json"),
                                   "description": .string("Based on \(current.manifest.name).")])
                .write(to: source.appending(path: "package.json"))
            try configurationData(saved.theme).write(to: source.appending(path: "config.json"))
            let installed = try await client.install(source, from: nil, origin: .saved)
            let choice = ThemeChoice(manifest: installed.manifest, directory: installed.directory, isBundled: false)
            choices.append(choice)
            // A theme can't hold widget styles, so they become the new theme's edits, after the old ones go: saving a
            // theme under its own name keeps the same profile.
            let profile = ThemeEdits(main: main, themeID: choice.manifest.id).profileName(theme: name)
            var changes = [edits.revertEdit].compactMap { $0 }
            changes += edits.changes.filter { $0.path.first == "widgetOverrides" }
                .map { $0.setting(profile: profile, themeID: choice.manifest.id) }
            if selecting { changes.append(try store.configurationStore.themeEdit(for: choice)) }
            perform(on: key) { try store.customizationHistory.change(changes, everyBar: everyBar) }
        } catch { errors[key] = errorMessage(error) }
    }

    /// Deletes every installed version of `choice`, and the edits the main file keeps for it.
    func delete(_ choice: ThemeChoice) async {
        do {
            try await store.packageLibrary.uninstallTheme(id: choice.manifest.id)
            let main = try store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)
            if let removal = ThemeEdits(main: main, themeID: choice.manifest.id).revertEdit {
                try store.customizationHistory.change(removal)
            }
            await refresh()
        } catch { errors[choice.key] = errorMessage(error) }
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

extension ThemeChoice {
    // A link can carry different bytes for a version already installed or downloaded from a source.
    var linkedPreviewKey: String { "linked:\(directory.path)" }
}
