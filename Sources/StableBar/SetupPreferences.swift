import Foundation

struct SetupPreferences: Equatable {
    enum Appearance: String, CaseIterable {
        case current = "Keep current", automatic = "Automatic", light = "Light", dark = "Dark"
    }

    enum Placement: String, CaseIterable {
        case current = "Keep current", top = "Top edge", belowMenuBar = "Below menu bar"
    }

    enum Clock: String, CaseIterable {
        case current = "Keep current", twentyFourHour = "24-hour", twelveHour = "12-hour"
    }

    enum Theme: Hashable {
        case current, builtIn, package(id: String, version: String?)
    }

    enum WidgetSet: Hashable {
        case system, meetings, workspaces(WorkspaceSource), battery, sound, menuBarItems

        enum State {
            case available, added, disabled, conflict
        }

        func state(in configuration: Configuration) -> State {
            let template = try! ConfigurationValue.object(widgets[0]).decoded(WidgetConfiguration.self)
            guard let widget = configuration.widgets.first(where: { $0.id == template.id }) else { return .available }
            let matches: Bool
            switch (template.content, widget.content) {
            case let (.provider(expected), .provider(actual)):
                matches = configuration.providers[actual]!.type == expected
            default:
                matches = widget.content == template.content
            }
            if !matches { return .conflict }
            return widget.enabled ? .added : .disabled
        }

        var title: String {
            switch self {
            case .system: "System"
            case .meetings: "Meetings"
            case .workspaces: "Workspaces"
            case .battery: "Battery"
            case .sound: "Sound"
            case .menuBarItems: "Menu bar items"
            }
        }

        var symbol: String {
            WidgetAddCatalog.builtIns.first { $0.properties?["type"] == widgets[0]["type"] }!.symbol
        }

        var widgets: [[String: ConfigurationValue]] {
            let json = switch self {
            case .system: #"""
                [
                  {
                    "id": "system-monitor", "type": "system", "position": "right",
                    "layout": {
                      "type": "row",
                      "children": [
                        { "type": "symbol", "name": "cpu" },
                        { "type": "field", "field": "text" },
                        { "type": "symbol", "name": "memorychip" },
                        {
                          "type": "row", "style": { "spacing": 0 },
                          "children": [{ "type": "field", "field": "memory" }, { "type": "text", "text": "%" }]
                        }
                      ]
                    },
                    "popup": {
                      "style": { "width": 280 },
                      "layout": {
                        "type": "column",
                        "children": [
                          { "type": "text", "text": "System", "role": "heading" },
                          { "type": "graph", "height": 36 },
                          {
                            "type": "row",
                            "children": [
                              { "type": "text", "text": "CPU", "role": "key" },
                              { "type": "field", "field": "cpu", "alignment": "trailing", "role": "value" },
                              { "type": "text", "text": "%", "role": "value", "style": { "width": 14 } }
                            ]
                          },
                          { "type": "progress", "source": "cpu", "height": 3, "role": "meter" },
                          {
                            "type": "row",
                            "children": [
                              { "type": "text", "text": "Memory", "role": "key" },
                              { "type": "field", "field": "memory", "alignment": "trailing", "role": "value" },
                              { "type": "text", "text": "%", "role": "value", "style": { "width": 14 } }
                            ]
                          },
                          { "type": "progress", "source": "memory", "height": 3, "role": "meter" },
                          { "type": "divider", "role": "separator" },
                          { "type": "text", "text": "Activity Monitor", "open": "com.apple.ActivityMonitor", "role": "button" }
                        ]
                      }
                    }
                  }
                ]
                """#
            case .meetings: #"""
                [
                  {
                    "id": "meeting", "type": "calendar", "position": "right",
                    "layout": {
                      "type": "row",
                      "children": [
                        { "type": "symbol", "source": "icon" },
                        { "type": "field", "field": "text" },
                        { "type": "field", "field": "start", "hideWhenEmpty": "start", "role": "secondary" }
                      ]
                    },
                    "popup": {
                      "style": { "width": 320 },
                      "layout": {
                        "type": "column",
                        "children": [
                          { "type": "text", "text": "Today", "role": "heading" },
                          {
                            "type": "list", "source": "today",
                            "row": {
                              "type": "row", "openField": "link",
                              "children": [
                                { "type": "field", "field": "start", "role": "key", "style": { "width": 56 } },
                                { "type": "field", "field": "title", "role": "primary" }
                              ]
                            }
                          },
                          { "type": "divider", "role": "separator" },
                          { "type": "text", "text": "Calendar", "open": "com.apple.iCal", "role": "button" }
                        ]
                      }
                    }
                  }
                ]
                """#
            case .workspaces: #"[{ "id": "workspaces", "type": "workspaces", "position": "left" }]"#
            case .battery: #"[{ "id": "battery", "type": "battery", "position": "right", "details": true }]"#
            case .sound: #"[{ "id": "sound", "type": "audio", "position": "right" }]"#
            case .menuBarItems: #"[{ "id": "menu-bar-items", "type": "menuBarItems", "position": "right" }]"#
            }
            return try! JSONDecoder().decode([[String: ConfigurationValue]].self, from: Data(json.utf8))
        }
    }

    enum Preset: CaseIterable {
        case minimal, developer, workday, notch, everything

        var title: String {
            switch self {
            case .minimal: "Minimal"
            case .developer: "Developer"
            case .workday: "Workday"
            case .notch: "Notch"
            case .everything: "Everything"
            }
        }

        var detail: String {
            switch self {
            case .minimal: "Built-in theme"
            case .developer: "Phosphor theme, dark"
            case .workday: "Léman theme"
            case .notch: "Notch theme"
            case .everything: "Catppuccin theme"
            }
        }

        var symbol: String {
            switch self {
            case .minimal: "minus"
            case .developer: "chevron.left.forwardslash.chevron.right"
            case .workday: "calendar"
            case .notch: "macbook"
            case .everything: "square.grid.2x2"
            }
        }

        /// Notch only blends into the notch on the top edge, so setup offers it once the bar replaces the menu bar.
        /// A Notch preset already chosen stays offered, so it can still be deselected.
        static func offered(on placement: Placement, keeping selected: Preset? = nil) -> [Preset] {
            allCases.filter { $0 != .notch || placement == .top || $0 == selected }
        }

        func preferences(workspaces: WorkspaceSource, placement: Placement) -> SetupPreferences {
            switch self {
            case .minimal: SetupPreferences(placement: placement, theme: .builtIn, widgetSets: [.sound, .menuBarItems])
            case .developer: SetupPreferences(appearance: .dark, placement: placement, theme: .package(id: "phosphor", version: nil),
                                              widgetSets: [.workspaces(workspaces), .system, .sound, .battery, .menuBarItems])
            case .workday: SetupPreferences(placement: placement, theme: .package(id: "leman", version: nil),
                                            widgetSets: [.meetings, .sound, .battery, .menuBarItems])
            case .notch: SetupPreferences(placement: placement, theme: .package(id: "notch", version: nil), widgetSets: [.sound, .battery, .menuBarItems])
            case .everything: SetupPreferences(placement: placement, theme: .package(id: "catppuccin", version: nil),
                                               widgetSets: [.workspaces(workspaces), .meetings, .system, .sound, .battery, .menuBarItems])
            }
        }
    }

    var appearance = Appearance.current
    var placement = Placement.current
    var clock = Clock.current
    var theme = Theme.current
    var widgetSets: [WidgetSet] = []
    var keepWindowsClear: Bool?
    var keepNotificationsClear: Bool?
    var deferMeetings = false

    func save(to url: URL, menuBarHeight: Double, context: ConfigurationContext) throws {
        let original = try Data(contentsOf: url)
        let data = try applying(to: original, menuBarHeight: menuBarHeight, configurationURL: url, context: context)
        try writeConfiguration(data, to: url)
    }

    func applying(to data: Data, menuBarHeight: Double, configurationURL: URL? = nil,
                  context: ConfigurationContext = ConfigurationContext()) throws -> Data {
        let configuration: Configuration
        if let configurationURL {
            var loader = ConfigurationLoader()
            configuration = try loader.load(configurationURL, data: data, context: context)
        } else {
            configuration = try JSONDecoder().decode(Configuration.self, from: data)
        }
        if self == SetupPreferences() { return data }
        var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        var ids = configuration.widgets.map(\.id)
        for edit in try edits(in: configuration, menuBarHeight: menuBarHeight) { document = try edit.applying(to: document, widgetIDs: &ids) }
        return try configurationData(document, editing: data)
    }

    func edits(in configuration: Configuration, menuBarHeight: Double) throws -> [ConfigurationEdit] {
        var edits: [ConfigurationEdit] = []
        switch theme {
        case .current: break
        case .builtIn: edits.append(ConfigurationEdit(action: .theme))
        case let .package(id, version):
            var properties: [String: ConfigurationValue] = ["id": .string(id)]
            if let version { properties["version"] = .string(version) }
            edits.append(ConfigurationEdit(action: .theme, properties: properties))
        }
        if appearance != .current {
            let value: ConfigurationValue = switch appearance {
            case .light: .string("light")
            case .dark: .string("dark")
            default: .null
            }
            edits.append(ConfigurationEdit(action: .bar, properties: ["appearance": value]))
        }
        if placement != .current {
            edits.append(ConfigurationEdit(action: .bar, properties: ["offset": .number(placement == .top ? 0 : menuBarHeight)]))
        }
        if let keepWindowsClear {
            edits.append(ConfigurationEdit(action: .bar, properties: ["keepWindowsClear": .bool(keepWindowsClear)]))
        }
        if let keepNotificationsClear {
            edits.append(ConfigurationEdit(action: .bar, properties: ["keepNotificationsClear": .bool(keepNotificationsClear)]))
        }
        if clock != .current {
            for widget in configuration.widgets {
                if case .clock = widget.content {
                    edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: [
                        "format": .string(clock == .twentyFourHour ? "EEE d MMM  HH:mm" : "EEE d MMM  h:mm a")
                    ]))
                }
            }
        }
        var order = configuration.widgets.map(\.id)
        var appended = order
        for set in widgetSets {
            let state = set.state(in: configuration)
            if state == .added || state == .conflict { continue }
            for var widget in set.widgets {
                let id = try widget["id"]!.decoded(String.self)
                let enabled = set != .meetings || !deferMeetings
                if state == .disabled {
                    if enabled {
                        edits.append(ConfigurationEdit(action: .unset, properties: [
                            "widgetOverrides": .object([id: .object(["enabled": .null])])
                        ]))
                        edits.append(ConfigurationEdit(action: .set, id: id, properties: ["enabled": .bool(true)]))
                    }
                    continue
                }
                if !enabled { widget["enabled"] = .bool(false) }
                edits.append(ConfigurationEdit(action: .add, properties: widget))
                appended.append(id)
                let ends = ["audio", "battery", "clock", "menuBarItems"]
                let end = try ends.firstIndex(of: widget["type"]!.decoded(String.self)) ?? -1
                let anchor = configuration.widgets.first { existing in
                    switch existing.content {
                    case .activeApp, .appMenu: widget["position"] == .string("left")
                    case .clock: widget["position"] == .string("right") && ends.firstIndex(of: "clock")! > end
                    case .menuBarItems: widget["position"] == .string("right") && ends.firstIndex(of: "menuBarItems")! > end
                    case let .provider(name):
                        widget["position"] == .string("right") && ends.firstIndex(of: configuration.providers[name]!.type) ?? -1 > end
                    default: false
                    }
                }
                order.insert(id, at: anchor.flatMap { order.firstIndex(of: $0.id) } ?? order.endIndex)
            }
        }
        if order != appended { edits.append(ConfigurationEdit(action: .reorder, ids: order)) }
        for case let .workspaces(source) in widgetSets
        where source != configuration.workspaceSource && WidgetSet.workspaces(source).state(in: configuration) != .conflict {
            edits.append(ConfigurationEdit(action: .workspaceSource, name: source.rawValue))
        }
        return edits
    }
}
