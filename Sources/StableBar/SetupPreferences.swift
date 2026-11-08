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

        /// Below the macOS menu bar, a preset leaves out Menu bar items, which the menu bar shows right above it.
        func preferences(workspaces: WorkspaceSource, placement: Placement) -> SetupPreferences {
            var preferences = basePreferences(workspaces: workspaces, placement: placement)
            preferences.workspaces = workspaces
            if placement == .belowMenuBar { preferences.widgetSets.removeAll { $0 == .menuBarItems } }
            return preferences
        }

        private func basePreferences(workspaces: WorkspaceSource, placement: Placement) -> SetupPreferences {
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
    /// The source of a starter bar's Workspaces, as setup detects it; nil leaves the configuration's source.
    var workspaces: WorkspaceSource?
    var keepWindowsClear: Bool?
    var keepNotificationsClear: Bool?
    var deferMeetings = false

    /// The starter bar on the top edge, in the menu bar's place: the widgets of Resources/config.json.
    static let menuBarStarter = widgets(#"""
        [
          { "id": "apple", "type": "appleMenu", "position": "left" },
          { "id": "app-menu", "type": "appMenu", "position": "left" },
          { "id": "sound", "type": "audio", "position": "right" },
          { "id": "clock", "type": "clock", "position": "right", "format": "EEE d MMM  HH:mm", "onClick": "open -a Calendar" },
          { "id": "menu-bar-items", "type": "menuBarItems", "position": "right" }
        ]
        """#)

    /// The starter bar below the macOS menu bar, which already shows the menus, the clock and the menu bar items.
    static let belowMenuBarStarter = WidgetSet.workspaces(.spaces).widgets + WidgetSet.system.widgets + WidgetSet.sound.widgets

    /// Whether `document` is still the starter below the menu bar with Spaces, as the first launch writes it when it
    /// finds no window manager, such as before the login shell's PATH arrives: no other files, profiles or overrides,
    /// the starter's widgets, and the bar at its starting offset.
    static func isFirstLaunchSpacesStarter(_ document: [String: ConfigurationValue]) -> Bool {
        let offset = (try? document["bar"]?.decoded([String: ConfigurationValue].self))?["offset"]
        return document["includes"] == nil && document["packages"] == nil && document["profiles"] == nil
            && document["widgetOverrides"] == nil && (offset == nil || offset == .number(0))
            && document["workspaceSource"] == .string(WorkspaceSource.spaces.rawValue)
            && (try? document["widgets"]?.decoded([[String: ConfigurationValue]].self)) == belowMenuBarStarter
    }

    /// The widgets of the menu bar starter that repeat the macOS menu bar.
    static let menuBarWidgetIDs: Set<String> = ["apple", "app-menu", "clock", "menu-bar-items"]

    private static func widgets(_ json: String) -> [[String: ConfigurationValue]] {
        try! JSONDecoder().decode([[String: ConfigurationValue]].self, from: Data(json.utf8))
    }

    private static func id(_ widget: [String: ConfigurationValue]) -> String {
        (try? widget["id"]?.decoded(String.self)) ?? ""
    }

    /// The widgets that the file, or one of its profiles, changes or places without changing their definitions:
    /// through `widgetOverrides`, a kind of screen's `layout` or `widgetOrder`.
    private static func changedIDs(in document: [String: ConfigurationValue]) -> Set<String> {
        var layers = [document]
        if case let .array(profiles)? = document["profiles"] {
            for case let .object(profile) in profiles {
                if case let .object(configuration)? = profile["configuration"] { layers.append(configuration) }
            }
        }
        func strings(_ value: ConfigurationValue?) -> [String] {
            guard case let .array(values)? = value else { return [] }
            return values.compactMap { if case let .string(id) = $0 { id } else { nil } }
        }
        return Set(layers.flatMap { layer -> [String] in
            var ids = strings(layer["widgetOrder"])
            if case let .object(overrides)? = layer["widgetOverrides"] { ids += overrides.keys }
            if case let .object(screens)? = layer["screens"] {
                for case let .object(screen) in screens.values {
                    if case let .object(layout)? = screen["layout"] { ids += layout.values.flatMap(strings) }
                }
            }
            return ids
        })
    }

    /// The bar the chosen placement starts from, and how the configuration's widgets change to get there.
    private struct StarterChange {
        var configuration: Configuration
        var removed: [String] = []
        var added: [[String: ConfigurationValue]] = []
        var isBelowMenuBarStarter = false
    }

    /// A configuration that is still a starter bar becomes the starter of the chosen placement. A changed one keeps
    /// its widgets, except that below the menu bar it loses the menu bar starter's unchanged copies of what the menu
    /// bar shows.
    private func starterChange(in configuration: Configuration, document: [String: ConfigurationValue]?) -> StarterChange {
        guard let document, let widgets = try? document["widgets"]?.decoded([[String: ConfigurationValue]].self) else {
            return StarterChange(configuration: configuration)
        }
        // Includes and packages can refer to these widgets from files setup doesn't edit, so their widgets stay.
        guard document["includes"] == nil, document["packages"] == nil else {
            return StarterChange(configuration: configuration, isBelowMenuBarStarter: widgets == Self.belowMenuBarStarter)
        }
        let ids = widgets.map(Self.id)
        func swap(to starter: [[String: ConfigurationValue]]) -> StarterChange? {
            var swapped = document
            swapped["widgets"] = .array(starter.map(ConfigurationValue.object))
            // Profiles apply through the loader; the bar the starter swaps to doesn't need them.
            swapped["profiles"] = nil
            swapped["profile"] = nil
            guard let data = try? JSONEncoder().encode(swapped),
                  let target = try? JSONDecoder().decode(Configuration.self, from: data) else { return nil }
            let starterIDs = starter.map(Self.id)
            return StarterChange(configuration: target, removed: ids.filter { !starterIDs.contains($0) },
                                 added: starter.filter { !ids.contains(Self.id($0)) },
                                 isBelowMenuBarStarter: starter == Self.belowMenuBarStarter)
        }
        // Widgets from includes or packages, or overrides and layouts in the file or its profiles, mean the bar has
        // changed, even when its file still lists a starter.
        let changed = Self.changedIDs(in: document)
        let isStarter = configuration.widgets.map(\.id) == ids && changed.isDisjoint(with: ids)
        if isStarter, placement == .belowMenuBar, widgets == Self.menuBarStarter, let change = swap(to: Self.belowMenuBarStarter) { return change }
        if isStarter, placement == .top, widgets == Self.belowMenuBarStarter, let change = swap(to: Self.menuBarStarter) { return change }
        let removed = placement != .belowMenuBar ? [] : widgets.filter { widget in
            let id = Self.id(widget)
            return Self.menuBarWidgetIDs.contains(id) && !changed.contains(id) && Self.menuBarStarter.contains(widget)
        }.map(Self.id)
        return StarterChange(configuration: configuration, removed: removed, isBelowMenuBarStarter: widgets == Self.belowMenuBarStarter)
    }


    func save(to url: URL, context: ConfigurationContext) throws {
        let original = try Data(contentsOf: url)
        let data = try applying(to: original, configurationURL: url, context: context)
        try writeConfiguration(data, to: url)
    }

    func applying(to data: Data, configurationURL: URL? = nil,
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
        let edits = try edits(in: configuration, document: document)
        if edits.isEmpty { return data }
        var ids = configuration.widgets.map(\.id)
        for edit in edits { document = try edit.applying(to: document, widgetIDs: &ids) }
        return try configurationData(document, editing: data)
    }

    /// The edits that turn `configuration` into the bar setup builds. `document` is the configuration file's own
    /// content, which tells whether its widgets are still a starter bar.
    func edits(in configuration: Configuration, document: [String: ConfigurationValue]? = nil) throws -> [ConfigurationEdit] {
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
            var properties: [String: ConfigurationValue] = ["offset": .number(0)]
            if placement == .belowMenuBar {
                properties["belowMenuBar"] = .bool(true)
            } else if configuration.bar.belowMenuBar {
                properties["belowMenuBar"] = .bool(false)
            }
            edits.append(ConfigurationEdit(action: .bar, properties: properties))
        }
        if let keepWindowsClear {
            edits.append(ConfigurationEdit(action: .bar, properties: ["keepWindowsClear": .bool(keepWindowsClear)]))
        }
        if let keepNotificationsClear {
            edits.append(ConfigurationEdit(action: .bar, properties: ["keepNotificationsClear": .bool(keepNotificationsClear)]))
        }
        let starter = starterChange(in: configuration, document: document)
        for id in starter.removed { edits.append(ConfigurationEdit(action: .remove, id: id)) }
        for widget in starter.added { edits.append(ConfigurationEdit(action: .add, properties: widget)) }
        let target = starter.configuration
        let kept = target.widgets.filter { !starter.removed.contains($0.id) }
        if clock != .current {
            for widget in kept {
                if case .clock = widget.content {
                    edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: [
                        "format": .string(clock == .twentyFourHour ? "EEE d MMM  HH:mm" : "EEE d MMM  h:mm a")
                    ]))
                }
            }
        }
        let below = placement == .belowMenuBar || placement == .current && configuration.bar.belowMenuBar
        var order = kept.map(\.id)
        var appended = configuration.widgets.map(\.id).filter { !starter.removed.contains($0) } + starter.added.map(Self.id)
        for set in widgetSets where !(below && set == .menuBarItems) {
            let state = set.state(in: target)
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
                let anchor = kept.first { existing in
                    switch existing.content {
                    case .activeApp, .appMenu: widget["position"] == .string("left")
                    case .clock: widget["position"] == .string("right") && ends.firstIndex(of: "clock")! > end
                    case .menuBarItems: widget["position"] == .string("right") && ends.firstIndex(of: "menuBarItems")! > end
                    case let .provider(name):
                        widget["position"] == .string("right") && ends.firstIndex(of: target.providers[name]!.type) ?? -1 > end
                    default: false
                    }
                }
                order.insert(id, at: anchor.flatMap { order.firstIndex(of: $0.id) } ?? order.endIndex)
            }
        }
        if order != appended { edits.append(ConfigurationEdit(action: .reorder, ids: order)) }
        var sources = widgetSets.compactMap { set -> WorkspaceSource? in if case let .workspaces(source) = set { source } else { nil } }
        if sources.isEmpty, starter.isBelowMenuBarStarter {
            // A starter that gains Workspaces without a detected manager uses macOS Spaces, which needs none.
            if let workspaces { sources = [workspaces] } else if starter.added.contains(where: { Self.id($0) == "workspaces" }) { sources = [.spaces] }
        }
        for source in sources where source != configuration.workspaceSource && WidgetSet.workspaces(source).state(in: target) != .conflict {
            edits.append(ConfigurationEdit(action: .workspaceSource, name: source.rawValue))
        }
        return edits
    }
}

/// A setting setup saves that an active profile controls, for setup's profile notice.
struct ProfileControlledSetting: Identifiable {
    let title: String
    let origin: ConfigurationOrigin

    var id: String { "\(title)\n\(origin.profile ?? "")" }

    /// The settings setup saves that active profiles control, once for each profile. Placement counts both the offset and
    /// `belowMenuBar`, so a profile that sets either one is named.
    static func all(in configuration: Configuration?, origins: [String: ConfigurationOrigin]) -> [ProfileControlledSetting] {
        let settings = [("Appearance", ["bar.appearance"]), ("Placement", ["bar.offset", "bar.belowMenuBar"]),
                        ("Window clearance", ["bar.keepWindowsClear"]), ("Notification clearance", ["bar.keepNotificationsClear"])]
            + (configuration?.widgets.flatMap { widget -> [(String, [String])] in
                var settings = [(widget.id, ["widgets.\(widget.id).enabled"])]
                if case .clock = widget.content { settings.append(("Clock \(widget.id)", ["widgets.\(widget.id).format"])) }
                return settings
            } ?? [])
        return settings.flatMap { title, paths in
            var profiles = Set<String>()
            return paths.compactMap { path -> ProfileControlledSetting? in
                guard let origin = origins[path], let profile = origin.profile, profiles.insert(profile).inserted else { return nil }
                return ProfileControlledSetting(title: title, origin: origin)
            }
        }
    }
}
