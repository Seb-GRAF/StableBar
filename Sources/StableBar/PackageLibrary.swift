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
    private var drafts: [String: PackageDraft] = [:]
    private var downloads: Set<URL> = []
    private var selectionRequest = 0
    private(set) var installed: [WidgetPackageManifest] = []
    private(set) var entries: [PackageIndex.Entry] = []
    private(set) var selections: [WidgetPackageSelection] = []
    private(set) var draft: PackageDraft?
    private var requestedID: String?
    private(set) var loading = false
    private(set) var loadingStore = false
    private(set) var getting: Set<String> = []
    private(set) var updating: Set<String> = []
    var pendingUpdate: PackageDraft?
    private(set) var updateAdditions: [String] = []
    var storeError: String?
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
        for manifest in installed.filter(isActive) + newest where !result.contains(where: { $0.id == manifest.id }) {
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

    func update(for manifest: WidgetPackageManifest) -> PackageIndex.Entry? {
        entries.first { $0.id == manifest.id && $0.version.compare(manifest.version, options: .numeric) == .orderedDescending }
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

    private func applyUpdate(_ draft: PackageDraft) async throws {
        let manifest = draft.inspection.manifest
        if !isInstalled(draft) { draft.inspection = try await client.install(draft.inspection.directory) }
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

    func source(_ draft: PackageDraft) -> PackageSource? {
        let manifest = draft.inspection.manifest
        let installed = packages.directory.appending(path: manifest.id).appending(path: manifest.version)
        if draft.inspection.directory == installed { return source(of: manifest) }
        if reviewing || downloads.contains(draft.inspection.directory) { return .store }
        return .local
    }

    func source(of manifest: WidgetPackageManifest) -> PackageSource? {
        entries.contains { $0.id == manifest.id } ? .listed : .installed
    }

    func shownWidgets(_ draft: PackageDraft) -> Int {
        let ids = draft.inspection.widgets.map(\.id)
        return store.configuration?.widgets.filter { ids.contains($0.id) && $0.enabled }.count ?? 0
    }

    func configurationChanged() {
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

    func loadInstalled() async {
        do {
            installed = try await client.installed()
            error = nil
            configurationChanged()
        } catch {
            self.error = errorMessage(error)
        }
    }

    func loadStore(reload: Bool = false) async {
        loadingStore = true
        defer { loadingStore = false }
        do {
            entries = try await (reload ? client.reloadIndex() : client.index()).packages
            storeError = nil
        } catch {
            storeError = errorMessage(error)
        }
    }

    func preview(_ manifest: WidgetPackageManifest) async throws -> PackagePreviewData {
        try await preview(client.inspect(packages.directory(id: manifest.id, version: manifest.version)))
    }

    func preview(_ entry: PackageIndex.Entry) async throws -> PackagePreviewData {
        if let screenshot = entry.screenshot {
            return try await PackagePreviewData(screenshot: fetch(screenshot))
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
        } else if let entry = entries.first(where: { $0.id == id }) {
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
            downloads.insert(inspection.directory)
            await select(inspection.directory)
        } catch {
            guard request == selectionRequest else { return }
            self.error = errorMessage(error)
            requestedID = nil
            loading = false
        }
    }

    func select(_ directory: URL) async {
        selectionRequest += 1
        let request = selectionRequest
        loading = true
        do {
            let inspection = try await client.inspect(directory)
            guard request == selectionRequest else { return }
            let key = inspection.manifest.versionKey
            if let saved = drafts[key] {
                await show(saved)
                return
            }
            let manifest = inspection.manifest
            let supplied = try WidgetSetup(store: store).savedSettings(for: manifest)
            let values = try manifest.values(supplied)
            let reviewed = try await client.inspect(directory, settings: values)
            guard request == selectionRequest else { return }
            let draft = PackageDraft(inspection: reviewed, settings: values)
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
        getting.insert(entry.id)
        defer { getting.remove(entry.id) }
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
                draft.inspection = try await client.install(draft.inspection.directory)
                draft.inspection = try await client.inspect(draft.inspection.directory, settings: draft.settings)
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
