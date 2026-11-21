import Foundation

struct SetupPreferences: Equatable, Codable, Sendable {
    enum Placement: String, CaseIterable, Codable, Sendable {
        case current = "Keep current", top = "Top edge", belowMenuBar = "Below menu bar"
    }

    /// The region's hour cycle, or the 24- or 12-hour one earlier setups offered, which a starter's clock can still have.
    enum Clock {
        case current, twentyFourHour, twelveHour
    }

    enum Theme: Hashable, Codable, Sendable {
        case current, package(id: String, version: String?)
    }

    enum WidgetSet: Hashable, Codable, Sendable {
        case appleMenu, appMenu(expandsOnHover: Bool), workspaces(WorkspaceSource, showsApps: Bool = true), system, systemMeters, systemRings,
             meetings, privacy, sound, battery, batteryLevel, batteryRing, dateAndTime, dayAndTime, menuBarItems
        /// A Store package's widget, which setup adds once the package's review has, starting from `settings`.
        case store(id: String, name: String, position: WidgetPosition, settings: [String: String] = [:])

        enum State {
            case available, added, disabled, conflict
        }

        /// A set of several widgets, such as the date and the time, conflicts when one of them does, so it goes on the
        /// bar whole or not at all.
        func state(in configuration: Configuration) -> State {
            if case let .store(id, _, _, _) = self {
                guard let widget = configuration.widgets.first(where: { $0.id == id }) else { return .available }
                return widget.enabled ? .added : .disabled
            }
            let states = widgets.map { Self.state(of: $0, in: configuration) }
            return states.contains(.conflict) ? .conflict : states.contains(.available) ? .available : states.contains(.disabled) ? .disabled : .added
        }

        private static func state(of widget: [String: ConfigurationValue], in configuration: Configuration) -> State {
            let template = try! ConfigurationValue.object(withoutLayout(widget)).decoded(WidgetConfiguration.self)
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
            case .appleMenu: "Apple menu"
            case .appMenu: "App menus"
            case .workspaces: "Workspaces"
            case .system, .systemMeters, .systemRings: "System"
            case .meetings: "Meetings"
            case .privacy: "Microphone & camera"
            case .sound: "Sound"
            case .battery, .batteryLevel, .batteryRing: "Battery"
            case .dateAndTime, .dayAndTime: "Date and time"
            case .menuBarItems: "Menu bar items"
            case let .store(_, name, _, _): name
            }
        }

        /// The IDs its widgets have on the bar.
        var ids: [String] {
            if case let .store(id, _, _, _) = self { [id] } else { widgets.map(SetupPreferences.id) }
        }

        /// The built-in widgets of this set; a Store widget has none.
        var widgets: [[String: ConfigurationValue]] {
            let json: String
            switch self {
            case .appleMenu: json = #"[{ "id": "apple", "type": "appleMenu", "position": "left" }]"#
            case let .appMenu(expandsOnHover):
                json = expandsOnHover ? #"[{ "id": "app-menu", "type": "appMenu", "position": "left", "expandOnHover": true }]"#
                    : #"[{ "id": "app-menu", "type": "appMenu", "position": "left" }]"#
            case let .workspaces(_, showsApps):
                json = showsApps ? #"[{ "id": "workspaces", "type": "workspaces", "position": "left" }]"#
                    : #"[{ "id": "workspaces", "type": "workspaces", "position": "left", "workspace": { "showApps": false } }]"#
            case .systemMeters: json = #"""
                [
                  {
                    "id": "system-monitor", "type": "system", "position": "right", "details": true,
                    "layout": {
                      "type": "row", "style": { "spacing": 14 },
                      "children": [
                        {
                          "type": "row", "style": { "spacing": 6 },
                          "children": [
                            { "type": "text", "text": "CPU", "role": "key", "style": { "fontWeight": "medium" } },
                            { "type": "field", "field": "text", "alignment": "trailing", "style": { "minWidth": 37 } },
                            { "type": "progress", "source": "cpu", "height": 4, "role": "meter", "style": { "width": 32 } }
                          ]
                        },
                        {
                          "type": "row", "style": { "spacing": 6 },
                          "children": [
                            { "type": "text", "text": "MEM", "role": "key", "style": { "fontWeight": "medium" } },
                            {
                              "type": "row", "alignment": "trailing", "style": { "spacing": 0, "minWidth": 37 },
                              "children": [{ "type": "field", "field": "memory" }, { "type": "text", "text": "%" }]
                            },
                            { "type": "progress", "source": "memory", "height": 4, "role": "meter", "style": { "width": 32 } }
                          ]
                        }
                      ]
                    }
                  }
                ]
                """#
            case .batteryLevel: json = #"""
                [
                  {
                    "id": "battery", "type": "battery", "position": "right", "details": true,
                    "layout": { "type": "row", "children": [{ "type": "battery" }, { "type": "field", "field": "text" }] }
                  }
                ]
                """#
            case .systemRings: json = #"""
                [
                  {
                    "id": "system-monitor", "type": "system", "position": "right", "details": true,
                    "layout": {
                      "type": "row", "style": { "spacing": 10 },
                      "children": [
                        {
                          "type": "row", "style": { "spacing": 5 },
                          "children": [
                            {
                              "type": "ring", "source": "cpu", "lineWidth": 2, "style": { "iconSize": 18, "background": "@token.track" },
                              "children": [{ "type": "symbol", "name": "cpu", "style": { "iconSize": 8.5 } }]
                            },
                            { "type": "field", "field": "text" }
                          ]
                        },
                        {
                          "type": "row", "style": { "spacing": 5 },
                          "children": [
                            {
                              "type": "ring", "source": "memory", "lineWidth": 2, "style": { "iconSize": 18, "background": "@token.track" },
                              "children": [{ "type": "symbol", "name": "memorychip", "style": { "iconSize": 8.5 } }]
                            },
                            {
                              "type": "row", "style": { "spacing": 0 },
                              "children": [{ "type": "field", "field": "memory" }, { "type": "text", "text": "%" }]
                            }
                          ]
                        }
                      ]
                    }
                  }
                ]
                """#
            case .batteryRing: json = #"""
                [
                  {
                    "id": "battery", "type": "battery", "position": "right", "details": true,
                    "layout": {
                      "type": "row", "style": { "spacing": 5 },
                      "children": [
                        {
                          "type": "ring", "source": "percent", "lineWidth": 2, "style": { "iconSize": 18, "background": "@token.track" },
                          "children": [{ "type": "symbol", "source": "icon", "style": { "iconSize": 8.5 } }]
                        },
                        { "type": "field", "field": "text" }
                      ]
                    }
                  }
                ]
                """#
            case .privacy: json = #"[{ "id": "privacy", "type": "privacy", "position": "right" }]"#
            case .dateAndTime, .dayAndTime:
                // The Mac's own date order and hour cycle, as the starter's clock has.
                return [
                    ["id": .string("date"), "type": .string("clock"), "position": .string("right"), "role": .string("secondary"), "details": .bool(true),
                     "format": .string(SetupPreferences.dateFormat(self == .dateAndTime ? "EEEdMMM" : "EEEd", or: self == .dateAndTime ? "EEE d MMM" : "EEE d"))],
                    ["id": .string("clock"), "type": .string("clock"), "position": .string("right"), "role": .string("time"), "details": .bool(true),
                     "format": .string(SetupPreferences.timeFormat())]
                ]
            case .store: return []
            case .system: json = #"""
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
            case .meetings: json = #"""
                [
                  {
                    "id": "meeting", "type": "calendar", "position": "center", "priority": 1, "details": true,
                    "layout": {
                      "type": "row", "hideWhen": { "field": "phase", "equals": "none" }, "style": { "spacing": 6 },
                      "children": [
                        { "type": "symbol", "name": "calendar", "hideWhen": { "field": "phase", "equals": "live" } },
                        {
                          "type": "symbol", "name": "circle.fill", "showWhen": { "field": "phase", "equals": "live" },
                          "style": { "iconSize": 7, "foreground": { "light": "#28a745", "dark": "#30d158" } }
                        },
                        { "type": "field", "field": "title", "style": { "maxWidth": 170 } },
                        { "type": "field", "field": "start", "role": "secondary", "showWhen": { "field": "phase", "equals": "later" } },
                        {
                          "type": "row", "showWhen": [{ "field": "phase", "equals": "soon" }, { "field": "phase", "equals": "now" }],
                          "style": { "spacing": 3, "foreground": "@token.warning" },
                          "children": [{ "type": "text", "text": "in" }, { "type": "field", "field": "minutes" }, { "type": "text", "text": "min" }]
                        },
                        {
                          "type": "row", "showWhen": { "field": "phase", "equals": "live" }, "role": "secondary", "style": { "spacing": 3 },
                          "children": [{ "type": "field", "field": "minutes" }, { "type": "text", "text": "min left" }]
                        },
                        {
                          "type": "text", "text": "Join", "hideWhenEmpty": "joinCommand", "hideWhen": { "field": "phase", "equals": "later" },
                          "onClickField": "joinCommand",
                          "style": {
                            "background": { "light": "#34c75938", "dark": "#30d15847" }, "cornerRadius": 8,
                            "paddingHorizontal": 8, "paddingVertical": 2, "fontWeight": "semibold"
                          }
                        }
                      ]
                    }
                  }
                ]
                """#
            case .battery: json = #"[{ "id": "battery", "type": "battery", "position": "right", "details": true }]"#
            case .sound: json = #"[{ "id": "sound", "type": "audio", "position": "right" }]"#
            case .menuBarItems: json = #"[{ "id": "menu-bar-items", "type": "menuBarItems", "position": "right" }]"#
            }
            return try! JSONDecoder().decode([[String: ConfigurationValue]].self, from: Data(json.utf8))
        }
    }

    enum Preset: String, CaseIterable, Codable, Sendable {
        case everyday, minimal, developer, workday, dashboard

        var title: String {
            switch self {
            case .everyday: "Everyday"
            case .minimal: "Minimal"
            case .developer: "Developer"
            case .workday: "Workday"
            case .dashboard: "Dashboard"
            }
        }

        /// What the preset is for, in a line its card fits.
        var summary: String {
            switch self {
            case .everyday: "Music, weather and the date."
            case .minimal: "The app, battery and time."
            case .developer: "Code, servers and AI limits."
            case .workday: "Meetings, mic and camera."
            case .dashboard: "Your Mac at a glance."
            }
        }

        var symbol: String {
            switch self {
            case .everyday: "sun.max"
            case .minimal: "minus"
            case .developer: "chevron.left.forwardslash.chevron.right"
            case .workday: "calendar"
            case .dashboard: "gauge.with.dots.needle.67percent"
            }
        }

        /// The preset's bar where it sits. Below the macOS menu bar, it leaves out what the menu bar right above it
        /// shows: the Apple menu, the app's menus, the date and time, and Menu bar items. On a Mac without an internal
        /// battery, Battery would only show a plug and "AC", so the preset leaves it out.
        func preferences(workspaces: WorkspaceSource, placement: Placement, hasBattery: Bool = true) -> SetupPreferences {
            var preferences = SetupPreferences(placement: placement, widgetSets: widgetSets(workspaces: workspaces, below: placement == .belowMenuBar),
                                               workspaces: workspaces)
            if !hasBattery { preferences.widgetSets.removeAll { [.battery, .batteryLevel, .batteryRing].contains($0) } }
            return preferences
        }

        func accessibilityLabel(widgetSets: [WidgetSet]) -> String {
            "\(title). Widgets: \(widgetSets.map(\.title).joined(separator: ", "))."
        }

        private func widgetSets(workspaces: WorkspaceSource, below: Bool) -> [WidgetSet] {
            let nowPlaying = WidgetSet.store(id: "now-playing", name: "Now playing", position: .center)
            let weather = WidgetSet.store(id: "weather", name: "Weather", position: .right)
            let sets: [WidgetSet] = switch self {
            case .everyday: [.appleMenu, .appMenu(expandsOnHover: false), nowPlaying, weather, .sound, .batteryLevel, .dateAndTime, .menuBarItems]
            case .minimal where below: [.workspaces(workspaces, showsApps: false), .battery]
            case .minimal: [.appleMenu, .appMenu(expandsOnHover: true), .battery, .dayAndTime, .menuBarItems]
            case .developer:
                [.appleMenu, .workspaces(workspaces), .appMenu(expandsOnHover: true),
                 .store(id: "dev-servers", name: "Development servers", position: .right),
                 .store(id: "ai-usage", name: "AI usage", position: .right, settings: ["layout": "One line"]),
                 .systemMeters, .battery, .dateAndTime, .menuBarItems]
            case .workday:
                [.appleMenu, .appMenu(expandsOnHover: false), .meetings, .store(id: "dock-badges", name: "Dock badges", position: .right), .privacy,
                 .sound, .battery, .dateAndTime, .menuBarItems]
            case .dashboard:
                [.appleMenu, .workspaces(workspaces), .appMenu(expandsOnHover: true), nowPlaying, weather, .systemRings, .batteryRing, .sound,
                 .dateAndTime, .menuBarItems]
            }
            guard below else { return sets }
            return sets.filter { set in !set.widgets.contains { SetupPreferences.menuBarWidgetIDs.contains(SetupPreferences.id($0)) } }
        }
    }

    var placement = Placement.current
    var theme = Theme.current
    /// The preset's widgets in bar order, which replace the bar's.
    var widgetSets: [WidgetSet] = []
    /// The source of a starter bar's Workspaces, as setup detects it; nil leaves the configuration's source.
    var workspaces: WorkspaceSource?
    var keepWindowsClear: Bool?
    var deferMeetings = false
    /// The Store packages picked under Found on your Mac, with the settings their review chose.
    var packages: [Package] = []
    /// The Store packages of the preset's widgets that their review added, with the settings it chose.
    var storeWidgets: [Package] = []

    struct Package: Equatable, Codable, Sendable {
        let id: String
        let version: String
        let settings: [String: ConfigurationValue]
    }

    /// Presets own widget sets and the Store widgets their review added. Every other choice stays, even a Meetings
    /// choice this preset doesn't use: it applies again after another change.
    func replacingPresetChoices(with preset: SetupPreferences) -> SetupPreferences {
        var merged = self
        merged.widgetSets = preset.widgetSets
        merged.storeWidgets = preset.storeWidgets
        return merged
    }

    /// The starter bar on the top edge as Resources/config.json and earlier releases write it, with a 24-hour clock in
    /// day-month order.
    static let bundledMenuBarStarter = widgets(#"""
        [
          { "id": "apple", "type": "appleMenu", "position": "left" },
          { "id": "app-menu", "type": "appMenu", "position": "left" },
          { "id": "sound", "type": "audio", "position": "right" },
          { "id": "clock", "type": "clock", "position": "right", "format": "EEE d MMM  HH:mm", "onClick": "open -a Calendar" },
          { "id": "menu-bar-items", "type": "menuBarItems", "position": "right" }
        ]
        """#)

    /// The starter bar on the top edge, in the menu bar's place: the widgets of Resources/config.json, with a clock in
    /// the Mac's date order and hour cycle.
    static var menuBarStarter: [[String: ConfigurationValue]] { menuBarStarter(clockFormat: clockFormat()) }

    static func menuBarStarter(locale: Locale) -> [[String: ConfigurationValue]] {
        menuBarStarter(clockFormat: clockFormat(locale: locale))
    }

    /// The starter bar on the top edge with its clock in `clockFormat`.
    static func menuBarStarter(clockFormat: String) -> [[String: ConfigurationValue]] {
        bundledMenuBarStarter.map { widget in
            guard widget["type"] == .string("clock") else { return widget }
            var widget = widget
            widget["format"] = .string(clockFormat)
            return widget
        }
    }

    static let starterClockFormatsKey = "starterClockFormats"

    /// The formats setup writes for the starter's clock in `locale`: the region's own, and its 24- and 12-hour choices.
    static func starterClockFormats(locale: Locale = .current) -> [String] {
        var formats: [String] = []
        for hours in [Clock.current, .twentyFourHour, .twelveHour] where !formats.contains(clockFormat(locale: locale, hours: hours)) {
            formats.append(clockFormat(locale: locale, hours: hours))
        }
        return formats
    }

    /// Remembers the starter clock formats this Mac's region gives, so a starter written under it still counts as one
    /// after the region changes. StableBar calls it at every launch.
    static func rememberStarterClockFormat(in defaults: UserDefaults = .standard) {
        var formats = rememberedStarterClockFormats(in: defaults)
        let new = starterClockFormats().filter { !formats.contains($0) }
        guard !new.isEmpty else { return }
        formats += new
        defaults.set(formats, forKey: starterClockFormatsKey)
    }

    /// The starter clock formats of the regions this Mac has had while StableBar ran.
    static func rememberedStarterClockFormats(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: starterClockFormatsKey) ?? []
    }

    /// Whether `widgets` are the starter bar on the top edge: with the bundled clock, or with a clock setup writes for
    /// this Mac's region now or wrote under an earlier one, its 24- and 12-hour choices included. A clock someone set
    /// to another format doesn't count.
    static func isMenuBarStarter(_ widgets: [[String: ConfigurationValue]],
                                 remembered: [String] = rememberedStarterClockFormats()) -> Bool {
        starters(remembered: remembered).contains(widgets)
    }

    /// The starter bar on the top edge with each clock it can have on this Mac.
    private static func starters(remembered: [String]) -> [[[String: ConfigurationValue]]] {
        // Earlier releases' setup wrote its 12-hour choice as EEE d MMM  h:mm a.
        let formats = starterClockFormats() + remembered + ["EEE d MMM  h:mm a"]
        return [bundledMenuBarStarter] + formats.map { menuBarStarter(clockFormat: $0) }
    }

    /// StableBar's clock, day, date, two spaces and time, in `locale`'s date order and its hour cycle, or the 24- or
    /// 12-hour one `hours` picks: `EEE d MMM  HH:mm` in the UK, `EEE MMM d  h:mm a` in the US.
    static func clockFormat(locale: Locale = .current, hours: Clock = .current) -> String {
        dateFormat("EEEdMMM", or: "EEE d MMM", locale: locale) + "  " + timeFormat(locale: locale, hours: hours)
    }

    /// The time alone, in `locale`'s hour cycle or the 24- or 12-hour one `hours` picks.
    static func timeFormat(locale: Locale = .current, hours: Clock = .current) -> String {
        // The 24- and 12-hour choices keep their own time pattern: macOS can force a template to the other hour cycle.
        switch hours {
        case .twentyFourHour: "HH:mm"
        case .twelveHour: "h:mm a"
        case .current: dateFormat("jmm", or: "HH:mm", locale: locale)
        }
    }

    /// `template` in `locale`'s order, without commas and with plain spaces.
    static func dateFormat(_ template: String, or fallback: String, locale: Locale = .current) -> String {
        (DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? fallback)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The bundled starter as a new configuration starts: its clock in the Mac's date order and hour cycle. Any other
    /// file is left as it is.
    static func withMacsClock(_ data: Data, locale: Locale = .current) throws -> Data {
        var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        guard (try? document["widgets"]?.decoded([[String: ConfigurationValue]].self)) == bundledMenuBarStarter else { return data }
        document["widgets"] = .array(menuBarStarter(locale: locale).map(ConfigurationValue.object))
        return try configurationData(document, editing: data)
    }

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

    /// `widget` without its layout, which can name the theme's tokens that only the loader has. Telling widgets apart
    /// doesn't need it.
    private static func withoutLayout(_ widget: [String: ConfigurationValue]) -> [String: ConfigurationValue] {
        widget.filter { $0.key != "layout" }
    }

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
            swapped["widgets"] = .array(starter.map { .object(Self.withoutLayout($0)) })
            // Profiles apply through the loader; the bar the starter swaps to doesn't need them.
            swapped["profiles"] = nil
            swapped["profile"] = nil
            guard let data = try? JSONEncoder().encode(swapped),
                  let target = try? JSONDecoder().decode(Configuration.self, from: data) else { return nil }
            return StarterChange(configuration: target, removed: widgets.filter { !starter.contains($0) }.map(Self.id),
                                 added: starter.filter { !widgets.contains($0) },
                                 isBelowMenuBarStarter: starter == Self.belowMenuBarStarter)
        }
        // Widgets from includes or packages, or overrides and layouts in the file or its profiles, mean the bar has
        // changed, even when its file still lists a starter.
        let changed = Self.changedIDs(in: document)
        let isStarter = configuration.widgets.map(\.id) == ids && changed.isDisjoint(with: ids)
        let presetBar = widgetSets.flatMap(added)
        if isStarter, !presetBar.isEmpty, Self.isMenuBarStarter(widgets) || widgets == Self.belowMenuBarStarter, let change = swap(to: presetBar) {
            return change
        }
        if isStarter, placement == .belowMenuBar, Self.isMenuBarStarter(widgets), let change = swap(to: Self.belowMenuBarStarter) { return change }
        if isStarter, placement == .top, widgets == Self.belowMenuBarStarter, let change = swap(to: Self.menuBarStarter) { return change }
        let removed = placement != .belowMenuBar ? [] : widgets.filter { widget in
            let id = Self.id(widget)
            return Self.menuBarWidgetIDs.contains(id) && !changed.contains(id)
                && Self.starters(remembered: Self.rememberedStarterClockFormats()).contains { $0.contains(widget) }
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
        var loader = ConfigurationLoader()
        if let configurationURL {
            configuration = try loader.load(configurationURL, data: data, context: context)
        } else {
            configuration = try JSONDecoder().decode(Configuration.self, from: data)
        }
        if self == SetupPreferences() { return data }
        var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        let edits = try edits(in: configuration, document: document, widgetPackageIDs: loader.widgetPackageIDs)
        if edits.isEmpty { return data }
        var ids = configuration.widgets.map(\.id)
        for edit in edits { document = try edit.applying(to: document, widgetIDs: &ids) }
        return try configurationData(document, editing: data)
    }

    /// The edits that turn `configuration` into the bar setup builds. `document` is the configuration file's own
    /// content, which tells whether its widgets are still a starter bar.
    func edits(in configuration: Configuration, document: [String: ConfigurationValue]? = nil,
               widgetPackageIDs: [String: String] = [:]) throws -> [ConfigurationEdit] {
        var edits: [ConfigurationEdit] = []
        switch theme {
        case .current: break
        case let .package(id, version):
            var properties: [String: ConfigurationValue] = ["id": .string(id)]
            if let version { properties["version"] = .string(version) }
            edits.append(ConfigurationEdit(action: .theme, properties: properties))
        }
        if placement != .current {
            var properties: [String: ConfigurationValue] = ["offset": .number(0)]
            if placement == .belowMenuBar {
                properties["belowMenuBar"] = .bool(true)
            } else if configuration.bar.belowMenuBar {
                properties["belowMenuBar"] = .bool(false)
            }
            if configuration.bar.position == .bottom {
                properties["position"] = .string("top")
            }
            edits.append(ConfigurationEdit(action: .bar, properties: properties))
        }
        if let keepWindowsClear {
            edits.append(ConfigurationEdit(action: .bar, properties: ["keepWindowsClear": .bool(keepWindowsClear)]))
        }
        var starter = starterChange(in: configuration, document: document)
        let presetIDs = widgetSets.flatMap(\.ids)
        // The preset's bar replaces a changed bar's widgets. Removing one that another file defines turns it off.
        if !widgetSets.isEmpty {
            starter.removed += configuration.widgets.map(\.id).filter { !presetIDs.contains($0) && !starter.removed.contains($0) }
        }
        for id in starter.removed { edits.append(ConfigurationEdit(action: .remove, id: id)) }
        for widget in starter.added { edits.append(ConfigurationEdit(action: .add, properties: widget)) }
        let target = starter.configuration
        // A starter that becomes the preset's bar can trade a widget for another with the same ID.
        let kept = target.widgets.filter { widget in !starter.removed.contains(widget.id) || starter.added.contains { Self.id($0) == widget.id } }
        var order = kept.map(\.id)
        // The preset's widgets the bar already has take the preset's order among themselves.
        let retained = presetIDs.filter(order.contains)
        for (slot, id) in zip(order.indices.filter { retained.contains(order[$0]) }, retained) { order[slot] = id }
        var appended = configuration.widgets.map(\.id).filter { !starter.removed.contains($0) } + starter.added.map(Self.id)
        /// Before the widget that follows `id` on the preset's bar, once that one is on the bar.
        func next(after id: String) -> Int? {
            presetIDs.drop { $0 != id }.dropFirst().first(where: order.contains).flatMap { order.firstIndex(of: $0) }
        }
        for set in widgetSets where set.state(in: target) != .conflict {
            if case let .store(id, _, position, _) = set {
                // A Store widget turned off on the bar is turned on again where the preset has it, like a built-in one.
                if set.state(in: target) == .disabled, widgetPackageIDs[id] == id {
                    edits.append(ConfigurationEdit(action: .unset, properties: [
                        "widgetOverrides": .object([id: .object(["enabled": .null])])
                    ]))
                    edits.append(ConfigurationEdit(action: .set, id: id, properties: ["enabled": .bool(true), "position": .string(position.rawValue)]))
                    continue
                }
                guard set.state(in: target) == .available, (packages + storeWidgets).contains(where: { $0.id == id }) else { continue }
                edits.append(ConfigurationEdit(action: .set, id: id, properties: ["position": .string(position.rawValue)]))
                // Without an order, a package's widgets come before the file's own.
                appended.insert(id, at: 0)
                order.insert(id, at: next(after: id) ?? order.endIndex)
                continue
            }
            for widget in added(set) {
                let id = Self.id(widget)
                // The set doesn't conflict, so a widget with this ID is this one.
                if let existing = target.widgets.first(where: { $0.id == id }) {
                    if !existing.enabled && widget["enabled"] == nil {
                        edits.append(ConfigurationEdit(action: .unset, properties: [
                            "widgetOverrides": .object([id: .object(["enabled": .null])])
                        ]))
                        edits.append(ConfigurationEdit(action: .set, id: id, properties: ["enabled": .bool(true)]))
                    }
                    // Minimal below the menu bar shows Workspaces as numbers only, on the bar's own Workspaces too.
                    if let workspace = widget["workspace"] {
                        edits.append(ConfigurationEdit(action: .set, id: id, properties: ["workspace": workspace]))
                    }
                    continue
                }
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
                order.insert(id, at: next(after: id) ?? anchor.flatMap { order.firstIndex(of: $0.id) } ?? order.endIndex)
            }
        }
        if order != appended { edits.append(ConfigurationEdit(action: .reorder, ids: order)) }
        var sources = widgetSets.compactMap { set -> WorkspaceSource? in if case let .workspaces(source, _) = set { source } else { nil } }
        if sources.isEmpty, starter.isBelowMenuBarStarter {
            // A starter that gains Workspaces without a detected manager uses macOS Spaces, which needs none.
            if let workspaces { sources = [workspaces] } else if starter.added.contains(where: { Self.id($0) == "workspaces" }) { sources = [.spaces] }
        }
        for source in sources where source != configuration.workspaceSource && WidgetSet.workspaces(source).state(in: target) != .conflict {
            edits.append(ConfigurationEdit(action: .workspaceSource, name: source.rawValue))
        }
        for package in packages + storeWidgets {
            edits.append(ConfigurationEdit(action: .package, properties: [
                "id": .string(package.id), "version": .string(package.version), "enabled": .bool(true), "settings": .object(package.settings)
            ]))
        }
        return edits
    }

    /// `set`'s widgets as setup adds them: Meetings turned off while it waits for Calendars.
    private func added(_ set: WidgetSet) -> [[String: ConfigurationValue]] {
        set.widgets.map { widget in
            var widget = widget
            if set == .meetings && deferMeetings { widget["enabled"] = .bool(false) }
            return widget
        }
    }
}
