import Foundation
import Observation

struct PackagePreviewData: Sendable {
    var screenshot: Data?
    var theme: ThemePreview?
    var widgets: [WidgetConfiguration] = []
}

@MainActor @Observable
final class PackageDraft {
    var inspection: WidgetPackageInspection
    var settings: [String: ConfigurationValue]
    var secrets: [String: String] = [:]
    var savedSecrets: Set<String>?
    var screenshotData: Data?
    var themePreview: ThemePreview?
    var error: String?
    var credentialsError: String?
    var checking = false
    var working = false
    /// The source whose Store card or update opened this draft; nil for a folder or the Installed list.
    /// Adding the draft installs the package for that source, or claims the installed version for it.
    var sourceID: String?
    @ObservationIgnored var inspectionTask: Task<Void, Never>?

    init(inspection: WidgetPackageInspection, settings: [String: ConfigurationValue]) {
        self.inspection = inspection
        self.settings = settings
    }
}

@MainActor @Observable
final class PackageLibrary {
    nonisolated static let updateWidgetID = "stablebar.package-updates"
    private unowned let store: BarStore
    private let client: PackageStoreClient
    private let packages: WidgetPackageStore
    private let reviewing: Bool
    private let preferences: UserDefaults
    private var dismissedUpdates: Set<String>
    @ObservationIgnored private var updateTimer: Timer?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    var notifiesAboutUpdates: Bool {
        didSet {
            preferences.set(notifiesAboutUpdates, forKey: "notifyPackageUpdates")
            if notifiesAboutUpdates { startUpdateChecks() } else { stopUpdateChecks() }
        }
    }
    /// Installed and opened drafts by `versionKey`; Store drafts by `"\(sourceID):\(versionKey)"`.
    private var drafts: [String: PackageDraft] = [:]
    /// The private sources the configuration had when it was last read.
    @ObservationIgnored private var configuredSources: [PackageSource]?
    private var selectionRequest = 0
    private(set) var installed: [WidgetPackageManifest] = []
    private(set) var entries: [PackageIndex.Entry] = []
    /// The Store, then the private sources, as the client had them when the Store last loaded.
    private(set) var sources: [PackageSource] = [.store]
    /// Package ID → the source that installed it.
    private(set) var records: [String: PackageInstallRecord] = [:]
    /// Source ID → why its index didn't load.
    private(set) var sourceErrors: [String: String] = [:]
    /// The sources whose index loaded the last time the Store loaded.
    private(set) var loadedSources: Set<String> = []
    /// The last reload started by a change to `packageSources`; tests await it.
    @ObservationIgnored private(set) var sourceSync: Task<Void, Never>?
    private(set) var selections: [WidgetPackageSelection] = []
    private(set) var draft: PackageDraft?
    private var requestedID: String?
    private(set) var loading = false
    private(set) var loadingStore = false
    /// Store entries being installed, by `key`.
    private(set) var getting: Set<String> = []
    private(set) var updating: Set<String> = []
    var pendingUpdate: PackageDraft?
    private(set) var updateAdditions: [String] = []
    var storeError: String? { sourceErrors[PackageSource.storeID] }
    var error: String?
    var search = ""
    var showingStore = false

    init(store: BarStore, client: PackageStoreClient? = nil, reviewing: Bool = false, preferences: UserDefaults = .standard) {
        self.store = store
        self.client = client ?? store.packageStoreClient
        self.packages = WidgetPackageStore(directory: store.configurationURL.deletingLastPathComponent().appending(path: "packages"))
        self.reviewing = reviewing
        self.preferences = preferences
        notifiesAboutUpdates = preferences.object(forKey: "notifyPackageUpdates") as? Bool ?? true
        dismissedUpdates = Set(preferences.stringArray(forKey: "dismissedPackageUpdates") ?? [])
    }

    func startUpdateChecks() {
        guard notifiesAboutUpdates, updateTimer == nil else { return }
        let timer = Timer(fire: Date(timeIntervalSinceNow: 15), interval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateTask = Task { [weak self] in
                    guard let self else { return }
                    await self.loadInstalled()
                    await self.loadStore(reload: true)
                }
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    func stopUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        updateTask?.cancel()
        updateTask = nil
    }

    private var updateKeys: [String] {
        updates.map { "\($0.id)/\(update(for: $0)!.version)" }
    }

    var updateWidget: WidgetConfiguration? {
        guard notifiesAboutUpdates, updateKeys.contains(where: { !dismissedUpdates.contains($0) }) else { return nil }
        return try! ConfigurationValue.object([
            "id": .string(Self.updateWidgetID), "position": .string("right"), "type": .string("text"),
            "text": .string(String(updates.count)), "icon": .string("shippingbox"),
            "tooltip": .string("\(updates.count) package updates available"), "overflow": .string("never")
        ]).decoded(WidgetConfiguration.self)
    }

    func dismissUpdates() {
        dismissedUpdates.formUnion(updateKeys)
        preferences.set(dismissedUpdates.sorted(), forKey: "dismissedPackageUpdates")
    }

    func openUpdates() {
        showingStore = false
        search = ""
        deselect()
        store.onCustomizePackages?()
    }

    var selectedID: String? { requestedID ?? draft?.inspection.manifest.id }

    var installedPackages: [WidgetPackageManifest] {
        var result: [WidgetPackageManifest] = []
        let newest = installed.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        for manifest in installed.filter(isActive) + newest where !result.contains(where: { $0.id == manifest.id })
            && !WidgetAddCatalog.includes(manifest, record: records[manifest.id]) {
            result.append(manifest)
        }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func isInstalled(_ draft: PackageDraft) -> Bool {
        let manifest = draft.inspection.manifest
        return installed.contains { $0.id == manifest.id && $0.version == manifest.version }
    }

    func isActive(_ draft: PackageDraft) -> Bool {
        isActive(draft.inspection.manifest)
    }

    func isActive(_ manifest: WidgetPackageManifest) -> Bool {
        selections.contains { $0.id == manifest.id && $0.version == manifest.version && $0.enabled }
    }

    var hasPrivateSources: Bool { sources.contains { !$0.isStore } }

    func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? id
    }

    private func name(of record: PackageInstallRecord) -> String {
        sources.first { $0.id == record.source }?.name ?? record.name ?? record.source
    }

    /// The only source an installed package can update from: the one that installed it.
    /// Packages without a record, or opened from a folder, update from the Store; a removed source gives none.
    func updateSourceID(for manifest: WidgetPackageManifest) -> String? {
        guard !WidgetAddCatalog.includes(manifest, record: records[manifest.id]) else { return nil }
        guard let record = records[manifest.id], !record.isLocal else { return PackageSource.storeID }
        return sources.contains { $0.id == record.source } ? record.source : nil
    }

    func update(for manifest: WidgetPackageManifest) -> PackageIndex.Entry? {
        guard let sourceID = updateSourceID(for: manifest) else { return nil }
        return entries.first {
            $0.sourceID == sourceID && $0.id == manifest.id && $0.version.compare(manifest.version, options: .numeric) == .orderedDescending
        }
    }

    /// The name of the other source that installed this entry's ID, which must be uninstalled before getting it.
    func installedElsewhere(_ entry: PackageIndex.Entry) -> String? {
        guard let record = records[entry.id], !record.isLocal, record.source != entry.sourceID else { return nil }
        return name(of: record)
    }

    var updates: [WidgetPackageManifest] { installedPackages.filter { update(for: $0) != nil } }

    func update(_ manifest: WidgetPackageManifest) async {
        guard let entry = update(for: manifest) else { return }
        updating.insert(manifest.id)
        defer { updating.remove(manifest.id) }
        do {
            let downloaded = try await client.packageForAdding(entry)
            let values = try downloaded.manifest.values(WidgetSetup(store: store).savedSettings(for: downloaded.manifest))
            let inspection = try await client.inspect(downloaded.directory, settings: values)
            let previous = try await client.inspect(packages.directory(id: manifest.id, version: manifest.version))
            let draft = PackageDraft(inspection: inspection, settings: values)
            draft.sourceID = entry.sourceID
            updateAdditions = inspection.additions(since: previous)
            if updateAdditions.isEmpty {
                try await applyUpdate(draft)
            } else {
                pendingUpdate = draft
            }
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    func confirmUpdate(_ draft: PackageDraft) async {
        pendingUpdate = nil
        let id = draft.inspection.manifest.id
        updating.insert(id)
        defer { updating.remove(id) }
        do { try await applyUpdate(draft); error = nil }
        catch { self.error = errorMessage(error) }
    }

    /// A draft from a source is recorded as that source's; anything else as a local folder.
    private func install(_ draft: PackageDraft) async throws -> WidgetPackageInspection {
        try await client.install(draft.inspection.directory, from: source(of: draft))
    }

    private func source(of draft: PackageDraft) async throws -> PackageSource? {
        guard let sourceID = draft.sourceID else { return nil }
        guard let source = await client.source(id: sourceID) else { throw PackageSourceError.notConfigured(sourceID) }
        return source
    }

    private func applyUpdate(_ draft: PackageDraft) async throws {
        let manifest = draft.inspection.manifest
        if !isInstalled(draft) {
            draft.inspection = try await install(draft)
        } else if let source = try await source(of: draft) {
            // The update reviewed the source's files; the installed version is enabled only when it has them, as Add does.
            try await client.claim(manifest, from: source, reviewed: draft.inspection.directory)
        }
        configurationChanged()
        if let selection = selections.first(where: { $0.id == manifest.id }) {
            try store.customizationHistory.flush()
            let selectionEdit = edit(draft, enabled: selection.enabled)
            var edits = [selectionEdit]
            if manifest.kind != .theme && selection.enabled {
                var loader = ConfigurationLoader()
                loader.themesDirectory = store.themesDirectory
                let root = try store.editedDocument([selectionEdit], replaying: [])
                let configured = try loader.load(store.configurationURL, data: configurationData(root), context: store.context)
                let previous = store.configuration!.widgets
                let ids = draft.inspection.widgets.map(\.id)
                for widget in previous where ids.contains(widget.id) {
                    if let updated = configured.widgets.first(where: { $0.id == widget.id }) {
                        var properties: [String: ConfigurationValue] = [:]
                        if updated.position != widget.position { properties["position"] = .string(widget.position.rawValue) }
                        if updated.enabled != widget.enabled { properties["enabled"] = .bool(widget.enabled) }
                        if !properties.isEmpty { edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: properties)) }
                    }
                }
                let configuredIDs = configured.widgets.map(\.id)
                let previousIDs = previous.map(\.id)
                let order = previousIDs.filter { configuredIDs.contains($0) } + configuredIDs.filter { !previousIDs.contains($0) }
                if order != configuredIDs { edits.append(ConfigurationEdit(action: .reorder, ids: order)) }
            }
            try store.customizationHistory.change(edits)
        }
        await loadInstalled()
        if selectedID == manifest.id {
            drafts[manifest.versionKey] = nil
            await selectInstalled(manifest)
        }
        store.customizationHistory.showNotice("\(manifest.name) updated to \(manifest.version).")
    }

    func origin(_ draft: PackageDraft) -> PackageOrigin? {
        let manifest = draft.inspection.manifest
        if isInstalledCopy(draft.inspection.directory, of: manifest) { return origin(of: manifest) }
        if let sourceID = draft.sourceID { return origin(sourceID: sourceID) }
        return reviewing ? .store : .local
    }

    func origin(of manifest: WidgetPackageManifest) -> PackageOrigin? {
        if WidgetAddCatalog.includes(manifest, record: records[manifest.id]) { return .builtIn }
        return .installed(record: records[manifest.id], version: manifest.version,
                   listedInStore: entries.contains { $0.sourceID == PackageSource.storeID && $0.id == manifest.id }, sources: sources)
    }

    func origin(of entry: PackageIndex.Entry) -> PackageOrigin {
        origin(sourceID: entry.sourceID)
    }

    private func origin(sourceID: String) -> PackageOrigin {
        sourceID == PackageSource.storeID ? .store : .privateSource(sourceName(sourceID))
    }

    func isInstalledCopy(_ directory: URL, of manifest: WidgetPackageManifest) -> Bool {
        directory == packages.directory.appending(path: manifest.id).appending(path: manifest.version)
    }

    /// Store entries of one kind (nil: both) and one source (nil: every source) that match the search
    /// by name, description, ID or source name. Entries with an update come first, then installed packages,
    /// including another source's copy, then the rest; each group by name, then in source order.
    func storeEntries(showingThemes: Bool?, sourceID: String?) -> [PackageIndex.Entry] {
        let updated = Set(updates.compactMap { update(for: $0)?.key }), owned = Set(installedPackages.map(\.id))
        let sourceOrder = Dictionary(sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func group(_ entry: PackageIndex.Entry) -> Int { updated.contains(entry.key) ? 0 : owned.contains(entry.id) ? 1 : 2 }
        return entries.filter { entry in
            (!WidgetAddCatalog.includes(entry) || owned.contains(entry.id))
                && (showingThemes == nil || showingThemes == (entry.kind == .theme)) && (sourceID == nil || entry.sourceID == sourceID)
                && matchesSearch(entry.name, entry.description, entry.id, sourceName(entry.sourceID))
        }.sorted {
            if group($0) != group($1) { return group($0) < group($1) }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.id != $1.id { return $0.id < $1.id }
            return sourceOrder[$0.sourceID, default: .max] < sourceOrder[$1.sourceID, default: .max]
        }
    }

    /// Matches an installed package by name, description, ID or the name of the source that installed it.
    func matchesSearch(_ manifest: WidgetPackageManifest) -> Bool {
        let source = records[manifest.id].flatMap { $0.isLocal(version: manifest.version) ? nil : name(of: $0) }
        return matchesSearch(manifest.name, manifest.description, manifest.id, source)
    }

    private func matchesSearch(_ fields: String?...) -> Bool {
        search.isEmpty || fields.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
    }

    func shownWidgets(_ draft: PackageDraft) -> Int {
        let ids = draft.inspection.widgets.map(\.id)
        return store.configuration?.widgets.filter { ids.contains($0.id) && $0.enabled }.count ?? 0
    }

    func configurationChanged() {
        syncSources()
        do {
            selections = try store.effectiveDocument["packages"]?.decoded([WidgetPackageSelection].self) ?? []
            if let theme = store.effectiveDocument["theme"] { selections.append(try theme.decoded(WidgetPackageSelection.self)) }
            if !reviewing {
                for draft in drafts.values where isActive(draft) && draft.error == nil {
                    let manifest = draft.inspection.manifest
                    let values = try manifest.values(WidgetSetup(store: store).savedSettings(for: manifest))
                    if values != draft.settings {
                        draft.settings = values
                        inspect(draft)
                    }
                }
            }
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// Undo and edits to `packageSources` reach the client, and the Store reloads with them.
    /// Compared with the previous configuration, not with the client, so sources set on the client directly stay.
    private func syncSources() {
        guard let configured = try? PackageSource.configured(in: store.effectiveDocument).filter({ !$0.isStore }) else { return }
        defer { configuredSources = configured }
        guard let previous = configuredSources, previous != configured else { return }
        sourceSync = Task { [client] in
            await client.setPrivateSources(configured)
            await loadStore(reload: true)
        }
    }

    /// Hands the configured sources to the client and loads them, so the sync after an edit has nothing left to do.
    private func applySources() async {
        let configured = (try? PackageSource.configured(in: store.effectiveDocument).filter { !$0.isStore }) ?? []
        configuredSources = configured
        await client.setPrivateSources(configured)
        await loadStore()
    }

    func loadInstalled() async {
        do {
            installed = try await client.installed()
            records = try await client.records()
            error = nil
            configurationChanged()
        } catch {
            self.error = errorMessage(error)
        }
    }

    func loadStore(reload: Bool = false) async {
        loadingStore = true
        defer { loadingStore = false }
        let catalog = await client.catalog(reload: reload)
        let previous = entries
        sources = await client.sources
        // A source that failed keeps the entries it last listed, so its updates don't vanish while offline.
        entries = sources.flatMap { source in
            catalog.errors[source.id] == nil ? catalog.entries.filter { $0.sourceID == source.id } : previous.filter { $0.sourceID == source.id }
        }
        sourceErrors = catalog.errors
        loadedSources = Set(sources.map(\.id).filter { catalog.errors[$0] == nil })
    }

    func preview(_ manifest: WidgetPackageManifest) async throws -> PackagePreviewData {
        try await preview(client.inspect(packages.directory(id: manifest.id, version: manifest.version)))
    }

    func preview(_ entry: PackageIndex.Entry) async throws -> PackagePreviewData {
        if entry.screenshot != nil {
            return try await PackagePreviewData(screenshot: client.screenshot(for: entry))
        }
        return try await preview(client.packageForAdding(entry))
    }

    private func preview(_ inspection: WidgetPackageInspection) async throws -> PackagePreviewData {
        let screenshot = try await client.screenshotData(for: inspection)
        let themesDirectory = store.themesDirectory
        let theme = try await Task.detached { () throws -> ThemePreview? in
            if inspection.manifest.kind == .theme {
                return try ThemePreview(choice: ThemeChoice(manifest: inspection.manifest, directory: inspection.directory, isBundled: false),
                                        themesDirectory: themesDirectory)
            }
            return nil
        }.value
        return PackagePreviewData(screenshot: screenshot, theme: theme, widgets: inspection.widgets)
    }

    func selectPackage(_ id: String) async {
        if let selection = selections.first(where: { $0.id == id && $0.enabled }),
           let manifest = installed.first(where: { $0.id == id && $0.version == selection.version }) {
            await selectInstalled(manifest)
        } else if let manifest = installedPackages.first(where: { $0.id == id }) {
            await selectInstalled(manifest)
        } else if let entry = entries.first(where: { $0.id == id && $0.sourceID == draft?.sourceID }) ?? entries.first(where: { $0.id == id }) {
            await selectStore(entry)
        }
    }

    func selectInstalled(_ manifest: WidgetPackageManifest) async {
        requestedID = manifest.id
        if let saved = drafts[manifest.versionKey] {
            selectionRequest += 1
            await show(saved)
            return
        }
        do { await select(try packages.directory(id: manifest.id, version: manifest.version)) }
        catch {
            self.error = errorMessage(error)
            requestedID = nil
        }
    }

    func selectStore(_ entry: PackageIndex.Entry) async {
        requestedID = entry.id
        selectionRequest += 1
        let request = selectionRequest
        loading = true
        do {
            let inspection = try await client.packageForAdding(entry)
            guard request == selectionRequest else { return }
            await select(inspection.directory, sourceID: entry.sourceID)
        } catch {
            guard request == selectionRequest else { return }
            self.error = errorMessage(error)
            requestedID = nil
            loading = false
        }
    }

    /// Opens a folder, an installed copy, or with `sourceID` a package from that source in the Store.
    func select(_ directory: URL, sourceID: String? = nil) async {
        selectionRequest += 1
        let request = selectionRequest
        loading = true
        do {
            let inspection = try await client.inspect(directory)
            guard request == selectionRequest else { return }
            let key = sourceID.map { "\($0):\(inspection.manifest.versionKey)" } ?? inspection.manifest.versionKey
            // A source's saved draft is reused only for the same files: its download, or the copy it installed.
            if let saved = drafts[key], sourceID == nil || saved.inspection.directory == directory {
                await show(saved)
                return
            }
            let manifest = inspection.manifest
            let supplied = try WidgetSetup(store: store).savedSettings(for: manifest)
            let values = try manifest.values(supplied)
            let reviewed = try await client.inspect(directory, settings: values)
            guard request == selectionRequest else { return }
            let draft = PackageDraft(inspection: reviewed, settings: values)
            draft.sourceID = sourceID
            drafts[key] = draft
            let preview = try await preview(reviewed)
            draft.screenshotData = preview.screenshot
            draft.themePreview = preview.theme
            guard request == selectionRequest else { return }
            await show(draft)
        } catch {
            guard request == selectionRequest else { return }
            self.error = errorMessage(error)
            requestedID = nil
            loading = false
        }
    }

    func deselect() {
        selectionRequest += 1
        draft = nil
        requestedID = nil
        loading = false
    }

    func get(_ entry: PackageIndex.Entry) async {
        getting.insert(entry.key)
        defer { getting.remove(entry.key) }
        do {
            _ = try await client.installWithoutReview(entry)
            await loadInstalled()
        } catch PackageStoreClientError.reviewRequired {
            await selectStore(entry)
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func show(_ draft: PackageDraft) async {
        self.draft = draft
        requestedID = nil
        loading = false
        error = nil
        do {
            draft.savedSecrets = try await client.savedSecrets(for: draft.inspection.manifest)
            draft.credentialsError = nil
        } catch {
            draft.savedSecrets = nil
            draft.credentialsError = errorMessage(error)
        }
    }

    func setSetting(_ name: String, value: ConfigurationValue, in draft: PackageDraft) {
        draft.settings[name] = value
        do {
            if isActive(draft) && !reviewing {
                try store.customizationHistory.changePackageSettings(edit(draft, enabled: true))
            }
            draft.error = nil
            inspect(draft)
        } catch {
            draft.error = errorMessage(error)
        }
    }

    private func inspect(_ draft: PackageDraft) {
        draft.inspectionTask?.cancel()
        draft.checking = true
        let values = draft.settings
        let directory = draft.inspection.directory
        draft.inspectionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let inspection = try await client.inspect(directory, settings: values)
                guard !Task.isCancelled else { return }
                draft.inspection = inspection
                draft.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                draft.error = errorMessage(error)
            }
            draft.checking = false
        }
    }

    func accessChanges(_ draft: PackageDraft) async throws -> [String] {
        let manifest = draft.inspection.manifest
        if let previous = selections.first(where: { $0.id == manifest.id && $0.enabled && $0.version != manifest.version }),
           let version = previous.version {
            let inspection = try await client.inspect(packages.directory(id: manifest.id, version: version), settings: previous.settings)
            return draft.inspection.additions(since: inspection)
        }
        return []
    }

    func add(_ draft: PackageDraft, onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)? = nil) async {
        draft.working = true
        defer { draft.working = false }
        do {
            draft.inspectionTask?.cancel()
            draft.inspection = try await client.inspect(draft.inspection.directory, settings: draft.settings)
            if !isInstalled(draft) {
                draft.inspection = try await install(draft)
                draft.inspection = try await client.inspect(draft.inspection.directory, settings: draft.settings)
                await loadInstalled()
            } else if let source = try await source(of: draft) {
                // As Get does: an unclaimed installed version with the draft's files becomes the source's;
                // one with other files, or another source's, is refused rather than enabled unreviewed.
                try await client.claim(draft.inspection.manifest, from: source, reviewed: draft.inspection.directory)
                await loadInstalled()
            }
            if let onEnable {
                try onEnable(draft.inspection, draft.settings)
            } else if draft.inspection.manifest.kind == .theme {
                try store.customizationHistory.change(edit(draft, enabled: true))
            } else {
                _ = try WidgetSetup(store: store).enable(draft.inspection, settings: draft.settings, position: .right)
            }
            draft.error = nil
            draft.checking = false
            configurationChanged()
            await saveCredentials(draft)
        } catch {
            draft.error = errorMessage(error)
        }
    }

    func saveCredentials(_ draft: PackageDraft) async {
        draft.working = true
        defer { draft.working = false }
        do {
            try await client.saveSecrets(draft.secrets, for: draft.inspection.manifest)
            draft.savedSecrets = try await client.savedSecrets(for: draft.inspection.manifest)
            draft.secrets = [:]
            draft.credentialsError = nil
        } catch {
            draft.credentialsError = errorMessage(error)
        }
    }

    func deactivate(_ draft: PackageDraft) {
        do {
            try store.customizationHistory.change(edit(draft, enabled: false))
            draft.error = nil
            configurationChanged()
        } catch {
            draft.error = errorMessage(error)
        }
    }

    func uninstall(_ manifest: WidgetPackageManifest) async {
        do {
            try store.uninstallPackage(id: manifest.id, version: manifest.version, fromCustomization: true)
            drafts[manifest.versionKey] = nil
            await loadInstalled()
            if draft?.inspection.manifest.versionKey == manifest.versionKey {
                draft = nil
                if let next = installedPackages.first(where: { $0.id == manifest.id }) { await selectInstalled(next) }
            }
        } catch {
            draft?.error = errorMessage(error)
        }
    }

    private func edit(_ draft: PackageDraft, enabled: Bool) -> ConfigurationEdit {
        let manifest = draft.inspection.manifest
        return ConfigurationEdit(action: manifest.kind == .theme ? .theme : .package, properties: [
            "id": .string(manifest.id), "version": .string(manifest.version),
            "enabled": .bool(enabled), "settings": .object(draft.settings)
        ])
    }
}

/// The Sources sheet: editing `packageSources` in the main configuration and the tokens in the Keychain.
/// Tokens are read and written only through the client, which trims them and never logs them.
extension PackageLibrary {
    /// The Store and the sources the configuration defines now, which `sources` only follows after a catalog load.
    func currentSources() -> [PackageSource] {
        (try? PackageSource.configured(in: store.effectiveDocument)) ?? [.store]
    }

    /// Only sources the main configuration file defines can be edited; one from an include is read-only.
    func isEditable(_ source: PackageSource) -> Bool {
        guard !source.isStore, let main = try? store.editedMainDocument(),
              let sources = try? main["packageSources"]?.decoded([[String: ConfigurationValue]].self) else { return false }
        return sources.contains { $0["id"] == .string(source.id) }
    }

    /// The name of the file that defines the source; nil when unknown.
    func definingFile(_ source: PackageSource) -> String? {
        store.origins["packageSources.\(source.id).id"].map { URL(fileURLWithPath: $0.file).lastPathComponent }
    }

    /// The IDs of the private sources with a saved token.
    func savedTokens() async -> Set<String> {
        var saved: Set<String> = []
        for source in sources where !source.isStore {
            if await client.tokenIsSaved(for: source.id) { saved.insert(source.id) }
        }
        return saved
    }

    /// Loads a source's index without caching it. A token is trimmed, and a blank one sends none.
    /// A nil token uses the one saved for the source, when the source is on the origin it was saved for.
    func check(_ source: PackageSource, token: String?) async throws -> PackageIndex {
        guard let token else { return try await client.checkWithSavedToken(source) }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await client.check(source, token: trimmed.isEmpty ? nil : trimmed)
    }

    /// Adds the source to the main configuration with Undo, and saves a non-blank token to the Keychain.
    /// Refuses an id the configuration already has, so adding never replaces a source.
    func addSource(_ source: PackageSource, token: String) async throws {
        guard !currentSources().contains(where: { $0.id == source.id }) else { throw PackageSourceError.idTaken(source.id) }
        try store.customizationHistory.change([Self.edit(source)])
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try await client.saveToken(token, for: source) }
        await applySources()
    }

    /// Saves a new name or URL, and a token unless it's nil. A read-only source only takes the token.
    /// A token stays bound to the origin it was saved for, so after a move to another host it isn't sent until
    /// a new one is saved, and Undo of the move brings back a working source.
    func updateSource(_ source: PackageSource, token: String?) async throws {
        if isEditable(source) { try store.customizationHistory.change([Self.edit(source)]) }
        if let token { try await client.saveToken(token, for: source) }
        await applySources()
    }

    /// Removes the source from the main configuration with Undo. Its token stays, so Undo brings it back working.
    func removeSource(_ id: String) async throws {
        try store.customizationHistory.change([ConfigurationEdit(action: .packageSource, id: id)])
        await applySources()
    }

    func removeToken(_ id: String) async throws {
        try await client.deleteToken(for: id)
        await loadStore()
    }

    private static func edit(_ source: PackageSource) -> ConfigurationEdit {
        ConfigurationEdit(action: .packageSource, properties: [
            "id": .string(source.id), "name": .string(source.name), "url": .string(source.url.absoluteString)
        ])
    }
}
