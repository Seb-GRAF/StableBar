import Foundation
import Observation

@MainActor @Observable
final class WidgetSetup {
    struct Review: Identifiable {
        let inspection: WidgetPackageInspection
        let position: WidgetPosition
        var id: String { inspection.manifest.versionKey }
    }

    private let store: BarStore
    private let client: PackageStoreClient
    private(set) var choices = WidgetAddCatalog.compose()
    private(set) var storeUnavailable = false
    private(set) var isAdding = false
    var review: Review?
    var error: String?

    init(store: BarStore, client: PackageStoreClient? = nil) {
        self.store = store
        self.client = client ?? store.packageStoreClient
    }

    func load() async {
        do {
            choices = WidgetAddCatalog.compose(try await client.widgetChoices())
            storeUnavailable = false
        } catch {
            choices = WidgetAddCatalog.compose()
            storeUnavailable = true
        }
    }

    func add(_ choice: WidgetAddChoice, to position: WidgetPosition) async -> String? {
        guard !isAdding else { return nil }
        isAdding = true
        defer { isAdding = false }
        do {
            error = nil
            if let entry = choice.package {
                let inspection = try await client.packageForAdding(entry)
                if !inspection.commands.isEmpty {
                    review = Review(inspection: inspection, position: position)
                    return nil
                }
                let installed = try await client.installWithoutReview(entry)
                let selections = try store.effectiveDocument["packages"]?.decoded([WidgetPackageSelection].self) ?? []
                let settings = selections.first { $0.id == entry.id && $0.version == entry.version }?.settings ?? [:]
                return try enable(installed, settings: settings, position: position)
            }
            let id = "widget-" + UUID().uuidString.prefix(8).lowercased()
            guard let edit = choice.add(position: position, id: id) else { return nil }
            try store.customizationHistory.change(edit)
            return id
        } catch {
            self.error = errorMessage(error)
            // History reports a write failure too; keep Add errors at their point of use.
            store.customizationHistory.error = nil
            return nil
        }
    }

    func enable(_ inspection: WidgetPackageInspection, settings: [String: ConfigurationValue], position: WidgetPosition) throws -> String? {
        try store.customizationHistory.flush()
        let selection = ConfigurationEdit(action: .package, properties: [
            "id": .string(inspection.manifest.id), "version": .string(inspection.manifest.version),
            "enabled": .bool(true), "settings": .object(settings)
        ])
        var loader = ConfigurationLoader()
        loader.themesDirectory = store.themesDirectory
        let root = try store.editedDocument([selection], replaying: [])
        let configured = try loader.load(store.configurationURL, data: configurationData(root), context: store.context)
        // Package widget IDs are global. Include existing disabled widgets when adding a
        // previously enabled package again, and leave unrelated widgets in place.
        var packageLoader = ConfigurationLoader()
        let layer = try packageLoader.readPackage(at: inspection.directory, manifest: inspection.manifest, settings: settings)
        let packageConfiguration = try ConfigurationValue.object(packageLoader.finish(layer, context: store.context)).decoded(Configuration.self)
        let ids = Set(packageConfiguration.widgets.map(\.id))
        let added = configured.widgets.filter { ids.contains($0.id) }
        guard !added.isEmpty else { throw CommandFailure(message: "This package has no widgets for the current setup.") }
        var edits = [selection]
        for widget in added {
            edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: ["position": .string(position.rawValue), "enabled": .bool(true)]))
        }
        let remaining = configured.widgets.filter { !ids.contains($0.id) }
        let insertion = remaining.lastIndex { $0.position == position }.map { $0 + 1 } ?? remaining.endIndex
        var order = remaining.map(\.id)
        order.insert(contentsOf: added.map(\.id), at: insertion)
        edits.append(ConfigurationEdit(action: .reorder, ids: order))
        try store.customizationHistory.change(edits)
        return added.first?.id
    }

    func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil) throws {
        let widgets = store.configuration?.widgets ?? []
        try requireSavedWidget(id, widgets: widgets)
        try store.customizationHistory.change(WidgetPlacement.move(id, to: position, before: anchor, widgets: widgets))
    }

    func move(_ id: String, by offset: Int) throws {
        let widgets = store.configuration?.widgets ?? []
        try requireSavedWidget(id, widgets: widgets)
        try store.customizationHistory.change(WidgetPlacement.move(id, by: offset, widgets: widgets))
    }

    func remove(_ id: String) throws {
        try store.customizationHistory.change(ConfigurationEdit(action: .remove, id: id))
    }

    private func requireSavedWidget(_ id: String, widgets: [WidgetConfiguration]) throws {
        guard let widget = widgets.first(where: { $0.id == id }) else { return }
        var loader = ConfigurationLoader()
        loader.themesDirectory = store.themesDirectory
        let saved = try loader.load(store.configurationURL, context: store.context)
        let savedIDs = Set(saved.widgets.map(\.id))
        let moving = widgets.filter { $0.id == id || (widget.group != nil && $0.group == widget.group) }
        guard moving.allSatisfy({ savedIDs.contains($0.id) }) else {
            throw CommandFailure(message: "Save or discard command-line changes before editing this widget.")
        }
    }
}
