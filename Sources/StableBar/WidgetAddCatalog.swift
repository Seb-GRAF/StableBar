import Foundation

struct WidgetAddChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let description: String
    var properties: [String: ConfigurationValue]?
    var package: PackageIndex.Entry?
    var isScript = false
    var replacesPackage: String?
    /// The private source a package comes from; nil for built-ins and the Store.
    var sourceName: String?

    func matches(_ search: String) -> Bool {
        search.isEmpty || "\(name) \(description) \(package == nil ? "Built in" : sourceName ?? "Store")".localizedCaseInsensitiveContains(search)
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

enum WidgetAddCatalog {
    static let builtIns: [WidgetAddChoice] = [
        .init(id: "clock", name: "Clock & date", symbol: "clock", description: "Time, date and a month calendar, in your time zone.", properties: ["type": .string("clock"), "format": .string("EEE d MMM  HH:mm"), "details": .bool(true)], replacesPackage: "date"),
        .init(id: "activeApp", name: "Active app", symbol: "macwindow", description: "The frontmost app’s name and icon.", properties: ["type": .string("activeApp")]),
        .init(id: "appleMenu", name: "Apple menu", symbol: "apple.logo", description: "The Apple menu. Needs Accessibility access.", properties: ["type": .string("appleMenu")]),
        .init(id: "appMenu", name: "App menus", symbol: "menubar.rectangle", description: "The frontmost app’s menus. Needs Accessibility access.", properties: ["type": .string("appMenu")]),
        .init(id: "controlCenter", name: "Control Center", symbol: "switch.2", description: "Opens macOS Control Center. Needs Accessibility access.", properties: ["type": .string("controlCenter")]),
        .init(id: "menuBarItems", name: "Menu bar items", symbol: "square.grid.2x2", description: "Every item in the macOS menu bar, in a list. Needs Accessibility access.", properties: ["type": .string("menuBarItems")]),
        .init(id: "battery", name: "Battery", symbol: "battery.100percent", description: "The native battery indicator, with charge, power and health details.", properties: ["type": .string("battery"), "details": .bool(true)], replacesPackage: "battery-status"),
        .init(id: "audio", name: "Sound", symbol: "speaker.wave.2", description: "The volume and current audio output.", properties: ["type": .string("audio")]),
        .init(id: "system", name: "System monitor", symbol: "cpu", description: "CPU, memory and the apps using them, with adjustable warnings.",
              properties: ["type": .string("system"), "details": .bool(true), "style": .object(["states": .object([
                "warning": .object(["foreground": .string("@token.warning"), "accent": .string("@token.warning")]),
                "critical": .object(["foreground": .string("@token.critical"), "accent": .string("@token.critical")])
              ])])], replacesPackage: "system-monitor"),
        .init(id: "network", name: "Network", symbol: "network", description: "Upload and download rates, with activity for each interface.", properties: ["type": .string("network"), "details": .bool(true)], replacesPackage: "network-speed"),
        .init(id: "calendar", name: "Calendar", symbol: "calendar", description: "Your next meeting and today’s agenda. Asks for Calendar access.", properties: ["type": .string("calendar"), "details": .bool(true)], replacesPackage: "calendar-agenda"),
        .init(id: "workspaces", name: "Workspaces", symbol: "rectangle.3.group", description: "Switch workspaces. Needs AeroSpace, yabai, OmniWM or macOS Spaces.", properties: ["type": .string("workspaces")]),
        .init(id: "text", name: "Text", symbol: "textformat", description: "Your own text and optional icon.", properties: ["type": .string("text"), "text": .string("New widget")]),
        .init(id: "spacer", name: "Spacer", symbol: "arrow.left.and.right", description: "Space between widgets.", properties: ["type": .string("spacer")]),
        .init(id: "script", name: "Script", symbol: "terminal", description: "Run a shell command on a schedule.", properties: ["type": .string("script"), "command": .string("date +%H:%M"), "interval": .number(30)], isScript: true)
    ]

    static func includes(_ entry: PackageIndex.Entry) -> Bool {
        entry.sourceID == PackageSource.storeID && entry.kind != .theme && builtIns.contains { $0.replacesPackage == entry.id }
    }

    static func includes(_ manifest: WidgetPackageManifest, record: PackageInstallRecord?) -> Bool {
        guard manifest.kind == .widgets else { return false }
        if let record {
            guard record.source == PackageSource.storeID || record.isLocal else { return false }
        }
        if record == nil || record?.isLocal(version: manifest.version) == true {
            guard manifest.repository?.absoluteString == "https://github.com/Seb-GRAF/stablebar-packages" else { return false }
        }
        return builtIns.contains { $0.replacesPackage == manifest.id }
    }

    /// Store packages keep `store/<id>`; a private source's are `store/<source id>/<id>`, so the same ID can appear once per source.
    static func compose(_ packages: [PackageIndex.Entry] = [], sourceNames: [String: String] = [:]) -> [WidgetAddChoice] {
        var choices = builtIns.filter { !$0.isScript }
        func order(_ entry: PackageIndex.Entry) -> String { entry.sourceID == PackageSource.storeID ? "" : entry.sourceID }
        for entry in packages.filter({ !includes($0) }).sorted(by: { ($0.name, $0.id, order($0)) < ($1.name, $1.id, order($1)) }) {
            if entry.sourceID == PackageSource.storeID {
                choices.append(.init(id: "store/\(entry.id)", name: entry.name, symbol: "shippingbox",
                                     description: entry.description ?? "Widgets from the Store.", package: entry))
            } else {
                let source = sourceNames[entry.sourceID] ?? entry.sourceID
                choices.append(.init(id: "store/\(entry.sourceID)/\(entry.id)", name: entry.name, symbol: "shippingbox",
                                     description: entry.description ?? "Widgets from \(source).", package: entry, sourceName: source))
            }
        }
        return choices + builtIns.filter(\.isScript)
    }
}

extension PackageStoreClient {
    /// The widget packages of every source that loaded.
    func widgetChoices() async throws -> [PackageIndex.Entry] {
        await catalog().widgets
    }
}
