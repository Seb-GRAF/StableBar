import Foundation

struct ConfigurationEditing: Sendable {
    let configurationURL: URL
    let configurationLoader: ConfigurationLoader
    let context: ConfigurationContext
    let sessionEdits: [ConfigurationEdit]
    let customizationEdits: [ConfigurationEdit]
    let release: String?

    func editedDocument(_ edits: [ConfigurationEdit], data: Data? = nil, replaying: [ConfigurationEdit]? = nil) throws -> [String: ConfigurationValue] {
        var root = try editedMainDocument(data: data, replaying: replaying)
        var loader = configurationLoader
        var ids = try widgetIDs(in: root, loader: &loader)
        for edit in edits {
            try edit.validateTargets(in: ids)
            root = try applying(edit, to: root, widgetIDs: &ids, widgetPackageIDs: loader.widgetPackageIDs)
            if edit.action == .profile || edit.action == .profiles || edit.action == .package {
                ids = try widgetIDs(in: root, loader: &loader)
            }
        }
        return root
    }

    private func widgetIDs(in root: [String: ConfigurationValue], loader: inout ConfigurationLoader) throws -> [String] {
        try loader.compose(configurationURL, data: configurationData(root), context: context)["widgets"]!
            .decoded([[String: ConfigurationValue]].self).map { try $0["id"]!.decoded(String.self) }
    }

    func applying(_ edit: ConfigurationEdit, to root: [String: ConfigurationValue], widgetIDs: inout [String],
                          widgetPackageIDs: [String: String]) throws -> [String: ConfigurationValue] {
        var root = root
        if edit.action == .package, edit.properties?["enabled"] == .bool(false) {
            for (widget, package) in widgetPackageIDs where edit.properties?["id"] == .string(package) {
                root = try removingReferences(to: widget, in: root)
            }
        }
        return try edit.applying(to: root, widgetIDs: &widgetIDs)
    }

    func editedMainDocument(data: Data? = nil, replaying: [ConfigurationEdit]? = nil) throws -> [String: ConfigurationValue] {
        let data = try data ?? Data(contentsOf: configurationURL)
        var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        var ids: [String] = []
        for edit in replaying ?? (customizationEdits + sessionEdits) { root = try edit.applying(to: root, widgetIDs: &ids) }
        return root
    }

    func customizationData(_ edits: [ConfigurationEdit], editing original: Data) throws -> Data {
        var edits = edits
        if !sessionEdits.isEmpty {
            var loader = configurationLoader
            let savedIDs = try loader.load(configurationURL, data: original, context: context).widgets.map(\.id)
            let temporaryIDs = Set(try configurationReplayingSession(over: original).0.widgets.map(\.id)).subtracting(savedIDs)
            for index in edits.indices {
                if edits[index].action == .reorder {
                    edits[index].ids = edits[index].ids?.filter { !temporaryIDs.contains($0) }
                } else if [.set, .remove, .unset].contains(edits[index].action),
                          let id = edits[index].id, temporaryIDs.contains(id) {
                    throw CommandFailure(message: "Save or discard command-line changes before editing this widget.")
                }
            }
        }
        let root = try editedDocument(edits, data: original, replaying: [])
        return try configurationData(root, editing: original, savedBy: release)
    }

    func configurationReplayingSession(over data: Data) throws -> (Configuration, ConfigurationLoader) {
        var loader = configurationLoader
        let saved = try loader.load(configurationURL, data: data, context: context)
        if sessionEdits.isEmpty { return (saved, loader) }
        let root = try editedMainDocument(data: data, replaying: sessionEdits)
        let next = try loader.load(configurationURL, data: configurationData(root), context: context)
        return (next, loader)
    }

    func requireSavedWidget(_ id: String, widgets: [WidgetConfiguration]) throws {
        guard !sessionEdits.isEmpty, let widget = widgets.first(where: { $0.id == id }) else { return }
        var loader = ConfigurationLoader()
        loader.themesDirectory = configurationLoader.themesDirectory
        let saved = try loader.load(configurationURL, context: context)
        let savedIDs = Set(saved.widgets.map(\.id))
        let moving = widgets.filter { $0.id == id || (widget.group != nil && $0.group == widget.group) }
        guard moving.allSatisfy({ savedIDs.contains($0.id) }) else {
            throw CommandFailure(message: "Save or discard command-line changes before editing this widget.")
        }
    }
}
