import Foundation

struct WidgetAddChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let description: String
    var properties: [String: ConfigurationValue]?
    var package: PackageIndex.Entry?
    var isScript = false

    var basicChoice: WidgetAddChoice? {
        guard package != nil, properties != nil else { return nil }
        var choice = self
        choice.package = nil
        return choice
    }

    var basicActionTitle: String { "Add Basic \(name)" }

    func matches(_ search: String) -> Bool {
        search.isEmpty || "\(name) \(description) \(package == nil ? "Built in" : "Store")".localizedCaseInsensitiveContains(search)
    }

    func add(position: WidgetPosition, id: String) -> ConfigurationEdit? {
        properties.map { ConfigurationEdit(action: .add, properties: $0.merging([
            "id": .string(id), "position": .string(position.rawValue)
        ]) { $1 }) }
    }

    func add(position: WidgetPosition, id: String, before anchor: String?, widgets: [WidgetConfiguration]) -> [ConfigurationEdit]? {
        guard let edit = add(position: position, id: id) else { return nil }
        guard anchor != nil else { return [edit] }
        var order = widgets.map(\.id)
        order.insert(id, at: WidgetPlacement.insertionIndex(at: position, before: anchor, widgets: widgets))
        return [edit, ConfigurationEdit(action: .reorder, ids: order)]
    }
}

struct WidgetStoreChoice: Sendable {
    let entry: PackageIndex.Entry
    let nativeSource: String?
}

enum WidgetAddCatalog {
    static let builtIns: [WidgetAddChoice] = [
        .init(id: "clock", name: "Clock", symbol: "clock", description: "The local date and time.", properties: ["type": .string("clock"), "format": .string("EEE d MMM  HH:mm")]),
        .init(id: "activeApp", name: "Active app", symbol: "macwindow", description: "The frontmost app’s name and icon.", properties: ["type": .string("activeApp")]),
        .init(id: "battery", name: "Battery", symbol: "battery.100percent", description: "Battery level and charging status.", properties: ["type": .string("battery")]),
        .init(id: "audio", name: "Sound", symbol: "speaker.wave.2", description: "The volume and current audio output.", properties: ["type": .string("audio")]),
        .init(id: "system", name: "CPU", symbol: "cpu", description: "CPU and memory use.", properties: ["type": .string("system")]),
        .init(id: "network", name: "Network", symbol: "network", description: "Your network connection and activity.", properties: ["type": .string("network")]),
        .init(id: "calendar", name: "Calendar", symbol: "calendar", description: "Upcoming events. Asks for Calendar access.", properties: ["type": .string("calendar")]),
        .init(id: "workspaces", name: "Workspaces", symbol: "rectangle.3.group", description: "Switch workspaces. Needs AeroSpace or yabai.", properties: ["type": .string("workspaces")]),
        .init(id: "text", name: "Text", symbol: "textformat", description: "Your own text and optional icon.", properties: ["type": .string("text"), "text": .string("New widget")]),
        .init(id: "spacer", name: "Spacer", symbol: "arrow.left.and.right", description: "Space between widgets.", properties: ["type": .string("spacer")]),
        .init(id: "script", name: "Script", symbol: "terminal", description: "Run a shell command on a schedule.", properties: ["type": .string("script"), "command": .string("date +%H:%M"), "interval": .number(30)], isScript: true)
    ]

    static func compose(_ packages: [WidgetStoreChoice] = []) -> [WidgetAddChoice] {
        var choices = builtIns.filter { !$0.isScript }
        for package in packages.sorted(by: { ($0.entry.name, $0.entry.id) < ($1.entry.name, $1.entry.id) }) {
            let entry = package.entry
            if let source = package.nativeSource, let index = choices.firstIndex(where: { $0.id == source }) {
                if choices[index].package == nil { choices[index].package = entry }
                // Retain the built-in name, description and permission/tool hints.
            } else {
                choices.append(.init(id: "store/\(entry.id)", name: entry.name, symbol: "shippingbox", description: entry.description ?? "Widgets from the Store.", package: entry))
            }
        }
        return choices + builtIns.filter(\.isScript)
    }
}

extension PackageStoreClient {
    func widgetChoices() async throws -> [WidgetStoreChoice] {
        let entries = try await index().packages.filter { $0.kind != .theme }
        var choices: [WidgetStoreChoice] = []
        for entry in entries {
            do {
                let inspection = try await package(entry)
                choices.append(WidgetStoreChoice(entry: entry, nativeSource: try nativeSource(inspection)))
            } catch {
                // An unavailable package leaves its built-in fallback available.
                continue
            }
        }
        return choices
    }

    private func nativeSource(_ inspection: WidgetPackageInspection) throws -> String? {
        guard inspection.commands.isEmpty else { return nil }
        var loader = ConfigurationLoader()
        let layer = try loader.readPackage(at: inspection.directory, manifest: inspection.manifest, settings: [:])
        let profiles = try layer.values["profiles"]?.decoded([ConfigurationProfile].self) ?? []
        var layers = [layer]
        for profile in profiles {
            var selected = layer
            selected.values["profile"] = .string(profile.name)
            layers.append(selected)
        }
        var sources = Set<String>()
        for layer in layers {
            let configuration = try ConfigurationValue.object(loader.finish(layer, context: ConfigurationContext())).decoded(Configuration.self)
            guard !configuration.widgets.isEmpty else { return nil }
            for widget in configuration.widgets {
                guard let name = widget.providerName, let provider = configuration.providers[name],
                      ["battery", "audio", "system", "network", "calendar"].contains(provider.type) else { return nil }
                sources.insert(provider.type)
            }
        }
        return sources.count == 1 ? sources.first : nil
    }
}
