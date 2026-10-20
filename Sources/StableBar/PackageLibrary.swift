import Foundation
import Observation

@MainActor @Observable
final class PackageDraft {
    var inspection: WidgetPackageInspection
    var settings: [String: ConfigurationValue]
    var secrets: [String: String] = [:]
    var savedSecrets: Set<String>?
    var screenshotData: Data?
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
    private unowned let store: BarStore
    private let client: PackageStoreClient
    private let packages: WidgetPackageStore
    private let reviewing: Bool
    private var drafts: [String: PackageDraft] = [:]
    private var selectionRequest = 0
    private(set) var installed: [WidgetPackageManifest] = []
    private(set) var entries: [PackageIndex.Entry] = []
    private(set) var selections: [WidgetPackageSelection] = []
    private(set) var draft: PackageDraft?
    private(set) var loading = false
    private(set) var loadingStore = false
    var storeError: String?
    var error: String?
    var search = ""
    var showingInstalled = false

    init(store: BarStore, client: PackageStoreClient? = nil, reviewing: Bool = false) {
        self.store = store
        self.client = client ?? store.packageStoreClient
        self.packages = WidgetPackageStore(directory: store.configurationURL.deletingLastPathComponent().appending(path: "packages"))
        self.reviewing = reviewing
    }

    var installedPackages: [WidgetPackageManifest] {
        var result: [WidgetPackageManifest] = []
        for manifest in installed.sorted(by: { $0.version.compare($1.version, options: .numeric) == .orderedDescending }) {
            if !result.contains(where: { $0.id == manifest.id }) { result.append(manifest) }
        }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func isInstalled(_ draft: PackageDraft) -> Bool {
        let manifest = draft.inspection.manifest
        return installed.contains { $0.id == manifest.id && $0.version == manifest.version }
    }

    func isActive(_ draft: PackageDraft) -> Bool {
        let manifest = draft.inspection.manifest
        return selections.contains { $0.id == manifest.id && $0.version == manifest.version && $0.enabled }
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
        if let saved = drafts[manifest.versionKey] {
            selectionRequest += 1
            await show(saved)
            return
        }
        do { await select(try packages.directory(id: manifest.id, version: manifest.version)) }
        catch { self.error = errorMessage(error) }
    }

    func selectStore(_ entry: PackageIndex.Entry) async {
        selectionRequest += 1
        let request = selectionRequest
        loading = true
        do {
            let inspection = try await client.packageForAdding(entry)
            guard request == selectionRequest else { return }
            await select(inspection.directory)
        } catch {
            guard request == selectionRequest else { return }
            self.error = errorMessage(error)
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
            draft.screenshotData = try await client.screenshotData(for: reviewed)
            guard request == selectionRequest else { return }
            await show(draft)
        } catch {
            guard request == selectionRequest else { return }
            self.error = errorMessage(error)
            loading = false
        }
    }

    private func show(_ draft: PackageDraft) async {
        self.draft = draft
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

    func uninstall(_ draft: PackageDraft) async {
        do {
            let manifest = draft.inspection.manifest
            try store.uninstallPackage(id: manifest.id, version: manifest.version, fromCustomization: true)
            drafts[manifest.versionKey] = nil
            self.draft = nil
            await loadInstalled()
        } catch {
            draft.error = errorMessage(error)
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
