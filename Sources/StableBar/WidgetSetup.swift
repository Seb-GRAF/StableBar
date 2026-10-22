import AppKit
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
    private(set) var storeError: String?
    private(set) var isLoading = false
    private(set) var isAdding = false
    private(set) var requestStarted = false
    var review: Review?
    var reviewIsWorking = false
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
        guard !reviewIsWorking else { return }
        review = nil
        requestStarted = false
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            choices = WidgetAddCatalog.compose(try await client.widgetChoices())
            storeUnavailable = false
            storeError = nil
        } catch {
            choices = WidgetAddCatalog.compose()
            storeUnavailable = true
            storeError = errorMessage(error)
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
                if inspection.requiresReview || !inspection.manifest.settings.isEmpty || inspection.widgets.count > 1 {
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
        var selections = try document["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        if let theme = document["theme"] { selections.append(try theme.decoded(WidgetPackageSelection.self)) }
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

    func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil, on kind: ScreenKind? = nil) throws {
        let widgets = store.configuration?.widgets ?? []
        try requireSavedWidget(id, widgets: widgets)
        if let kind, let configuration = store.configuration, hasOwnLayout(kind, in: configuration) {
            return try arrange(WidgetPlacement.arrangement(moving: id, to: position, before: anchor, widgets: configuration.onScreen(kind).widgets), on: kind)
        }
        var edits = try WidgetPlacement.move(id, to: position, before: anchor, widgets: widgets)
        if store.customizationHistory.editingProfile != nil, anchor == nil, edits.contains(where: { $0.action == .set }) {
            edits.removeAll { $0.action == .reorder }
        }
        try store.customizationHistory.change(edits)
    }

    func move(_ id: String, by offset: Int, on kind: ScreenKind? = nil, listed: (WidgetConfiguration) -> Bool = { _ in true }) throws {
        let widgets = store.configuration?.widgets ?? []
        try requireSavedWidget(id, widgets: widgets)
        if let kind, let configuration = store.configuration, hasOwnLayout(kind, in: configuration) {
            return try arrange(WidgetPlacement.arrangement(moving: id, by: offset, widgets: configuration.onScreen(kind).widgets, listed: listed), on: kind)
        }
        try store.customizationHistory.change(WidgetPlacement.move(id, by: offset, widgets: widgets, listed: listed))
    }

    private func hasOwnLayout(_ kind: ScreenKind, in configuration: Configuration) -> Bool {
        configuration.screenLayouts[kind.rawValue] != nil || Set(store.screenSetup?.kinds ?? []).count > 1
    }

    private func arrange(_ widgets: [WidgetConfiguration], on kind: ScreenKind) throws {
        try store.customizationHistory.change([layoutEdit(widgets, shownOn: kind, on: kind)])
    }

    func splitScreen(_ kind: ScreenKind) throws {
        try arrange(store.configuration!.onScreen(kind).widgets, on: kind)
    }

    func copyScreen(_ source: ScreenKind, to kind: ScreenKind) throws {
        let configuration = store.configuration!
        let displays = NSScreen.screens.map(BarDisplay.init)
        var edits = configuration.widgets.compactMap { widget -> ConfigurationEdit? in
            let shown = source.shows(widget.display, among: displays, activeID: store.activeDisplayID)
            guard shown != kind.shows(widget.display, among: displays, activeID: store.activeDisplayID) else { return nil }
            let kinds = ScreenKind.allCases.filter { $0 == kind ? shown : $0.shows(widget.display, among: displays, activeID: store.activeDisplayID) }
            return ConfigurationEdit(action: .set, id: widget.id, properties: ["display": .array(kinds.map { .string($0.selection) })])
        }
        edits.append(ConfigurationEdit(action: .unset, properties: ["screens": .object([kind.rawValue: .object(["bar": .null])])]))
        edits.append(layoutEdit(configuration.onScreen(source).widgets, shownOn: source, on: kind))
        let screens = try store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self) ?? [:]
        if let bar = screens[source.rawValue]?["bar"] {
            edits.append(ConfigurationEdit(action: .screens, properties: [kind.rawValue: .object(["bar": bar])]))
        }
        try store.customizationHistory.change(edits)
    }

    func joinScreen(_ kind: ScreenKind) throws {
        try store.customizationHistory.change([ConfigurationEdit(action: .unset, properties: ["screens": .object([kind.rawValue: .null])])])
    }

    private func layoutEdit(_ widgets: [WidgetConfiguration], shownOn source: ScreenKind, on kind: ScreenKind) -> ConfigurationEdit {
        let displays = NSScreen.screens.map(BarDisplay.init)
        let shown = widgets.filter { source.shows($0.display, among: displays, activeID: store.activeDisplayID) }
        let layout = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { position in
            (position.rawValue, ConfigurationValue.array(shown.filter { $0.position == position }.map { .string($0.id) }))
        })
        return ConfigurationEdit(action: .screens, properties: [kind.rawValue: .object(["layout": .object(layout)])])
    }

    func remove(_ id: String) throws {
        if let package = store.widgetPackageIDs[id] {
            var selection = try store.effectiveDocument["packages"]!.decoded([[String: ConfigurationValue]].self).first { $0["id"] == .string(package) }!
            selection["enabled"] = .bool(false)
            return try store.customizationHistory.change(ConfigurationEdit(action: .package, properties: selection))
        }
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
