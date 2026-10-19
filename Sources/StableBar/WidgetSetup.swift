import Foundation
import Observation

@MainActor @Observable
final class WidgetSetup {
    struct Review: Identifiable {
        let inspection: WidgetPackageInspection
        let position: WidgetPosition
        let before: String?
        var id: String { inspection.manifest.versionKey }
    }

    private let store: BarStore
    private let client: PackageStoreClient
    @ObservationIgnored private let widgetsForInsertion: () throws -> [WidgetConfiguration]
    private(set) var choices = WidgetAddCatalog.compose()
    private(set) var storeUnavailable = false
    private(set) var isAdding = false
    private(set) var requestStarted = false
    var review: Review?
    var error: String?

    init(store: BarStore, client: PackageStoreClient? = nil, widgetsForInsertion: (() throws -> [WidgetConfiguration])? = nil) {
        self.store = store
        self.client = client ?? store.packageStoreClient
        self.widgetsForInsertion = widgetsForInsertion ?? {
            var loader = ConfigurationLoader()
            loader.themesDirectory = store.themesDirectory
            let root = try store.editedDocument([], replaying: store.customizationEdits)
            return try loader.load(store.configurationURL, data: configurationData(root), context: store.context).widgets
        }
    }

    func addAnchor(at position: WidgetPosition) throws -> String? {
        guard position == .right || position == .notchLeft else { return nil }
        return try WidgetPlacement.addAnchor(at: position, widgets: widgetsForInsertion())
    }

    func beginSheet() {
        requestStarted = false
        review = nil
        error = nil
    }

    func cancelReview() {
        review = nil
        requestStarted = false
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

    func add(_ choice: WidgetAddChoice, to position: WidgetPosition, before anchor: String? = nil) async -> String? {
        guard !requestStarted, !Task.isCancelled else { return nil }
        requestStarted = true
        isAdding = true
        defer { isAdding = false }
        do {
            error = nil
            if let entry = choice.package {
                let inspection = try await client.packageForAdding(entry)
                try Task.checkCancellation()
                if inspection.requiresReview {
                    review = Review(inspection: inspection, position: position, before: anchor)
                    return nil
                }
                let installed = try await client.installWithoutReview(entry)
                try Task.checkCancellation()
                let settings = try savedSettings(for: installed.manifest)
                return try enable(installed, settings: settings, position: position, before: anchor)
            }
            let id = "widget-" + UUID().uuidString.prefix(8).lowercased()
            let widgets = try anchor == nil ? [] : widgetsForInsertion()
            guard let edits = choice.add(position: position, id: id, before: anchor, widgets: widgets) else {
                throw CommandFailure(message: "Choose a widget to add.")
            }
            try store.customizationHistory.change(edits)
            return id
        } catch {
            requestStarted = false
            self.error = error is CancellationError ? nil : errorMessage(error)
            // History reports a write failure too; keep Add errors at their point of use.
            store.customizationHistory.error = nil
            return nil
        }
    }

    func savedSettings(for manifest: WidgetPackageManifest) throws -> [String: ConfigurationValue] {
        var loader = ConfigurationLoader()
        loader.themesDirectory = store.themesDirectory
        let root = try store.editedDocument([], replaying: store.customizationEdits)
        let document = try loader.compose(store.configurationURL, data: configurationData(root), context: store.context)
        let selections = try document["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        return (selections.first { $0.id == manifest.id }?.settings ?? [:]).filter { name, value in
            manifest.settings[name]?.accepts(value) == true
        }
    }

    func enable(_ inspection: WidgetPackageInspection, settings: [String: ConfigurationValue], position: WidgetPosition, before anchor: String? = nil) throws -> String? {
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
        let selections = try store.effectiveDocument["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        if selections.contains(where: { $0.id == inspection.manifest.id && $0.enabled }),
           let existing = store.configuration?.widgets.first(where: { ids.contains($0.id) && $0.enabled }) {
            let previous = store.configuration?.widgets ?? []
            var edits = [selection]
            for widget in previous where ids.contains(widget.id) {
                if configured.widgets.first(where: { $0.id == widget.id })?.position != widget.position {
                    edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: ["position": .string(widget.position.rawValue)]))
                }
            }
            let configuredIDs = configured.widgets.map(\.id)
            let previousIDs = previous.map(\.id)
            let order = previousIDs.filter { configuredIDs.contains($0) } + configuredIDs.filter { !previousIDs.contains($0) }
            if order != configuredIDs { edits.append(ConfigurationEdit(action: .reorder, ids: order)) }
            try store.customizationHistory.change(edits)
            store.customizationHistory.showNotice("\(inspection.manifest.name) is already on the bar. Its widget is selected.")
            return existing.id
        }
        var edits = [selection]
        for widget in added {
            edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: ["position": .string(position.rawValue), "enabled": .bool(true)]))
        }
        let remaining = configured.widgets.filter { !ids.contains($0.id) }
        let insertion = WidgetPlacement.insertionIndex(at: position, before: anchor, widgets: remaining)
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

    func move(_ id: String, by offset: Int, listed: (WidgetConfiguration) -> Bool = { _ in true }) throws {
        let widgets = store.configuration?.widgets ?? []
        try requireSavedWidget(id, widgets: widgets)
        try store.customizationHistory.change(WidgetPlacement.move(id, by: offset, widgets: widgets, listed: listed))
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
